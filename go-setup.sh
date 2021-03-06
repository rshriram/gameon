#!/bin/bash

# Support environments with docker-machine
# For base linux users, 127.0.0.1 is fine, but w/ docker-machine we need to
# use the host ip instead. So we'll generate an over-ridden env file that
# will get passed/copied properly into the target servers
#
# Use this script when you're developing rooms, or a subset of
# Game On services
#
# One-time, initial setup
#

if [ -z ${JAVA_HOME} ]
then
  echo "JAVA_HOME is not set. Please set and re-run this script."
  exit 1
fi

NAME=${DOCKER_MACHINE_NAME-empty}
IP=127.0.0.1
if [ "$NAME" = "empty" ]
then
  echo "DOCKER_MACHINE_NAME is not set. If you don't use docker-machine, you can ignore this, or
  export DOCKER_MACHINE_NAME=''"
elif [ -n $NAME ]
then
  IP=$(docker-machine ip $NAME)
  rc=$?
  if [ $rc != 0 ] || [ -z ${DOCKER_HOST} ]
  then
    echo "Is your docker host running? Did you start docker-machine, e.g.
  docker-machine start default
  eval \$(docker-machine env default)"
    exit 1
  fi
  if [ ! -f gameon.${NAME}env ]
  then
    echo "Creating new environment file gameon.${NAME}env to contain environment variable overrides.
This file will use the docker host ip address ($IP).
When the docker containers are up, use https://$IP/ to connect to the game."
  fi
  cat gameon.env | sed  -e "s#127\.0\.0\.1\:6379#A8LOCALHOSTPRESERVE#g" | sed -e "s#127\.0\.0\.1#${IP}#g" | sed -e "s#A8LOCALHOSTPRESERVE#127\.0\.0\.1\:6379#" > gameon.${NAME}env
fi

# If the keystore directory doesn't exist, then we should generate
# the keystores we need for local signed JWTs to work
if [ ! -d keystore ]
then
  echo "Checking for keytool..."
  keytool -help > /dev/null 2>&1
  if [ $? != 0 ]
  then
     echo "Error: keytool is missing from the path, please correct this, then retry"
	 exit 1
  fi

  echo "Building pem extractor"
  mkdir -p setup-utils

  #HAProxy will need the private key in PEM format, but keytool
  # only allows us to save private keys in pkcs12, thankfully java
  # is pretty easy to use to create us a tool to export private keys
  # in PEM format.. so we'll just inline a small bit here to let us
  # do that later.
  # (Yes, you can do this with openssl, but we don't have that as a prereq)
cat > setup-utils/PemExporter.java << 'EOT'
  import java.util.*;
  import java.io.*;
  import java.security.*;

  public class PemExporter
  {
      private File keystoreFile;
      private String keyStoreType;
      private char[] keyStorePassword;
      private char[] keyPassword;
      private String alias;
      private File exportedFile;
      private static final byte[] CRLF = new byte[] {'\r', '\n'};

      public void export() throws Exception {
          KeyStore keystore = KeyStore.getInstance(keyStoreType);
          keystore.load(new FileInputStream(keystoreFile), keyStorePassword);
          Key key = keystore.getKey(alias, keyPassword);
          String encoded = Base64.getMimeEncoder(64,CRLF).encodeToString(key.getEncoded());
          FileWriter fw = new FileWriter(exportedFile);
          fw.write("-----BEGIN PRIVATE KEY-----\n");
          fw.write(encoded);
          fw.write("\n");
          fw.write("-----END PRIVATE KEY-----");
          fw.close();
      }

      public static void main(String args[]) throws Exception {
          PemExporter export = new PemExporter();
          export.keystoreFile = new File(args[0]);
          export.keyStoreType = args[1];
          export.keyStorePassword = args[2].toCharArray();
          export.alias = args[3];
          export.keyPassword = args[4].toCharArray();
          export.exportedFile = new File(args[5]);
          export.export();
      }
  }
EOT
  cd setup-utils
  $JAVA_HOME/bin/javac PemExporter.java
  if [ $? != 0 ]
  then
     echo "Error: failed to compile the certificate exported"
   exit 1
  fi
  cd ..

  echo "Generating key stores using ${IP}"
  #create the keystore dir.. (we're only here if it doesn't exist!)
  mkdir -p keystore
  #create a ca cert we'll import into all our trust stores..
  keytool -genkeypair \
    -alias gameonca \
    -keypass gameonca \
    -storepass gameonca \
    -keystore keystore/cakey.jks \
    -keyalg RSA \
    -keysize 2048 \
    -dname "CN=GameOnLocalDevCA, OU=The Amazing GameOn Certificate Authority, O=The Ficticious GameOn Company, L=Earth, ST=Happy, C=CA" \
    -ext KeyUsage="keyCertSign" \
    -ext BasicConstraints:"critical=ca:true" \
    -validity 9999
  #export the ca cert so we can add it to the trust stores
  keytool -exportcert \
    -alias gameonca \
    -keypass gameonca \
    -storepass gameonca \
    -keystore keystore/cakey.jks \
    -file keystore/gameonca.crt \
    -rfc
  #create the keypair we plan to use for our ssl/jwt signing
  keytool -genkeypair \
    -alias gameonappkey \
    -keypass testOnlyKeystore \
    -storepass testOnlyKeystore \
    -keystore keystore/key.jks \
    -keyalg RSA \
    -sigalg SHA1withRSA \
    -dname "CN=${IP},OU=GameOn Application,O=The Ficticious GameOn Company,L=Earth,ST=Happy,C=CA" \
    -validity 365
  #create the signing request for the app key
  keytool -certreq \
    -alias gameonappkey \
    -keypass testOnlyKeystore \
    -storepass testOnlyKeystore \
    -keystore keystore/key.jks \
    -file keystore/appsignreq.csr
  #sign the cert with the ca
  keytool -gencert \
    -alias gameonca \
    -keypass gameonca \
    -storepass gameonca \
    -keystore keystore/cakey.jks \
    -infile keystore/appsignreq.csr \
    -outfile keystore/app.cer
  #import the ca cert
  keytool -importcert \
    -alias gameonca \
    -storepass testOnlyKeystore \
    -keypass testOnlyKeystore \
    -keystore keystore/key.jks \
    -noprompt \
    -file keystore/gameonca.crt
  #import the signed cert
  keytool -importcert \
    -alias gameonappkey \
    -storepass testOnlyKeystore \
    -keypass testOnlyKeystore \
    -keystore keystore/key.jks \
    -noprompt \
    -file keystore/app.cer
  #change the alias of the signed cert
  keytool -changealias \
    -alias gameonappkey \
    -destalias default \
    -storepass testOnlyKeystore \
    -keypass testOnlyKeystore \
    -keystore keystore/key.jks
  #export the signed cert in pem format for proxy to use
  keytool -exportcert \
  -alias default \
  -storepass testOnlyKeystore \
  -keypass testOnlyKeystore \
  -keystore keystore/key.jks \
  -file keystore/app.pem \
  -rfc
  #export the private key in pem format for proxy to use
  $JAVA_HOME/bin/java -cp setup-utils PemExporter\
   keystore/key.jks \
   JCEKS \
   testOnlyKeystore \
   default \
   testOnlyKeystore \
   keystore/private.pem
  #concat the public and private key for haproxy
  cat keystore/app.pem keystore/private.pem > keystore/proxy.pem
  #add the cacert to the truststore
  keytool -importcert \
    -alias gameonca \
    -storepass truststore \
    -keypass truststore \
    -keystore keystore/truststore.jks \
    -noprompt \
    -trustcacerts \
    -file keystore/gameonca.crt
  #clean up the public cert..
  rm -f keystore/public.crt
fi

#check for selinux by looking for chcon and sestatus..
#needed for fedora else the keystore dirs cannot be mapped in by
#docker-compose volume mapping
if [ -x "$(type -P chcon)" ] && [ -x "$(type -P sestatus)" ]
then
  echo ""
  echo "SELinux detected, adding svirt_sandbox_file_t to keystore dir"
  chcon -Rt svirt_sandbox_file_t ./keystore
fi

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

echo " Downloading platform services (one time)"

docker-compose -f $SCRIPTDIR/platformservices.yml pull
rc=$?
if [ $rc != 0 ]
then
  echo "Trouble pulling required platform images, we need to sort that first"
  exit 1
fi

docker-compose pull
rc=$?
if [ $rc != 0 ]
then
  echo "Trouble pulling core images, we need to sort that first"
  exit 1
fi

echo "

If you haven't already, start the platform services with:
 ./go-platform-services.sh start

If all of that went well, rebuild the and launch the game-on docker containers with:
 ./go-run.sh all

The game will be running at https://${IP}/ when you're all done."
