#!/bin/bash
#
# Requires VPN connection established to actually renew
# Will try to setup Kerberos token (kinit <IKEA networkID>@IKEA.COM + klist)
#

WORKDIR=${HOME}/ikea/keys
mkdir -vp $WORKDIR

DOMAIN=IKEA.COM

# Use whatever command you like to fetch your AD user/networkID
#AD_USER="$(pass ikea/aduser 2>/dev/null)"
# Check if AD_USER is defined
if [ ! -z $AD_USER ];then
  echo " + Using ${AD_USER} as AD_USER"
else
  echo -n " + Gimme your networkID: "
  read AD_USER
fi

# For a different username send as argument
[[ $# -eq 1 ]] && CERT_UID=$1 || CERT_UID=$AD_USER

# Setup paths
prepend="${WORKDIR}/ikea-${CERT_UID}"
pkey="${prepend}.key"
pemlink="${prepend}.pem"
pemfile="${prepend}-$(date +%F).pem"
csrfile="${prepend}-$(date +%F).csr"
RENEW_DAYS="15"

if [ ! -f $pkey ];then 
  echo " - $pkey not found. Generating..."
  #openssl genrsa -out $pkey 4096
  openssl genpkey -algorithm RSA -out $pkey
fi 
if [ -f $pkey ];then 
  if (openssl rsa -in $pkey -check -noout > /dev/null 2>&1); then 
    echo " + Using $pkey as private key file. "
  else
    echo " - $pkey is invalid. Remove manually and restart"
    exit
  fi
fi

if [ -L $pemlink ];then
  READLINK=$(readlink -f $pemlink)
  echo -e " + Found $pemlink softlinking to \n +   ${READLINK}"
  cert=$READLINK
fi


# Check expire date of existing certificate
if [[ -e "${cert}" ]]; then
  echo " + Checking expire date of existing cert..."
  valid="$(openssl x509 -enddate -noout -in "${cert}" | cut -d= -f2- )"
  printf " + Valid till %s " "${valid}"
  if (openssl x509 -checkend $((RENEW_DAYS * 86400)) -noout -in "${cert}" > /dev/null 2>&1); then
    printf "(Longer than %d days). " "${RENEW_DAYS}"
    if [[ "${force_renew}" = "yes" ]]; then
      echo "Ignoring because renew was forced!"
    else
      # Certificate-Names unchanged and cert is still valid
      echo "Skipping renew!"
      renew="no"
    fi
  else
    echo "(Less than ${RENEW_DAYS} days). Renewing!"
    renew="yes"
  fi
fi

if [[ "$renew" == "no" ]]; then exit; fi
  
if [[ ! -e "${pemfile}" ]];then
  if [[ ! -e "${csrfile}" ]];then
    echo " + Generating new CSR."
    openssl req -new -key $pkey -out $csrfile -subj "/C=SE/ST=Skaane/O=IKEA/OU=IT/CN=${CERT_UID}.${DOMAIN}"
  else
    echo " + CSR exists."
    #openssl req -text -noout -verify -in $csrfile
  fi
  csr_data=$(<$csrfile)
else
  echo " ! Unexpectedly found $pemfile. Checking and stopping."
  openssl x509 -in $pemlink -noout -dates
  exit
fi

if ! (curl -so/dev/null https://pki.ikea.com 2>/dev/null);then
    echo " ! Failed connection check. Is VPN connection established?"
    exit
fi

if ! klist -s ; then
  echo " - No kerberos tkt found. Setting up"
  #AD_PASS="$(pass ikea/adpass 2>/dev/null)"
  echo -n " ? AD pass: "
  read -s AD_PASS
  echo -n "$AD_PASS" | kinit ${AD_USER}@${DOMAIN} 2>/dev/null && klist || echo -e " - Failed to get valid kerberos ticket. Exiting" && exit 
else
  echo " + Found valid kerberos ticket"
fi

csrfile_response=${csrfile}.response
if [[ ! -e $csrfile_response ]];then
  echo " + Submitting CSR" 
  curl -sS -o $csrfile_response --negotiate -u : \
	  --data-urlencode "CertRequest=${csr_data}" \
	  -d CertAttrib=CertificateTemplate:IKEAWorkstation \
	  -d SaveCert=yes \
	  -d Mode=newreq \
	  https://pki.ikea.com/certsrv/certfnsh.asp
  #curl -sS -o $csrfile_RESPONSE --negotiate -u "${AD_USER}@${DOMAIN}:" --data-urlencode "CertRequest=${CSR_DATA}" -d CertAttrib=CertificateTemplate:IKEAWorkstation -d SaveCert=yes -d Mode=newreq https://pki.ikea.com/certsrv/certfnsh.asp
fi

if [[ -e $csrfile_response ]];then
  echo " + Found CSR response. Fetching signed cert"
  cert_url=$(grep -Eo 'certnew.cer\?ReqID=[0-9]{7,8}&amp;Enc=b64' $csrfile_response)
  echo $cert_url
  curl -sS -o $pemfile --negotiate -u : https://pki.ikea.com/certsrv/$CERT_URL  
fi

if [[ -e $pemfile ]];then
  ln -sf $pemfile $pemlink
fi

