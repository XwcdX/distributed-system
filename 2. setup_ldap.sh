BASE_DN="dc=if,dc=petra,dc=ac,dc=id"
ROOT_PW_Gw="ldap123"
SSH_USER="ec2-user"
WORKER_NODES=("worker1" "worker2" "worker3" "worker4")

# Format: "uid:First Name:Last Name"
# Password will be generated as: login<uid> (e.g., logintc, loginaileen)
CUSTOM_USERS=(
    "tc:T:C"
    "aileen:Aileen:R"
    "sharon:Sharon:V"
    "kevin:Kevin:Tanaka"
    "yohan:Yohan:Sebastian"
)

SCRIPTS_DIR="$HOME/Scripts"
CONFIG_DIR="$HOME/configs"
LDAP_CONFIG_DIR="$CONFIG_DIR/ldap"

# ==========================================
# PART 0: PREPARE FILES
# ==========================================
echo ">>> [0] Preparing Directories..."
mkdir -p $LDAP_CONFIG_DIR
if [ -f "$SCRIPTS_DIR/LDAP.zip" ]; then
    echo "Unzipping LDAP.zip..."
    unzip -o -q "$SCRIPTS_DIR/LDAP.zip" -d $LDAP_CONFIG_DIR
    [ -d "$LDAP_CONFIG_DIR/LDAP" ] && mv $LDAP_CONFIG_DIR/LDAP/* $LDAP_CONFIG_DIR/ && rmdir $LDAP_CONFIG_DIR/LDAP
else
    echo "ERROR: LDAP.zip not found in $SCRIPTS_DIR !"
    echo "Please ensure ~/Scripts/LDAP.zip exists."
    exit 1
fi

echo ">>> [0] Installing OpenLDAP..."
sudo yum -y install openldap-servers openldap-clients nss-pam-ldapd
sudo systemctl enable slapd
sudo systemctl start slapd

echo ">>> [0.5] Loading Standard Schemas..."
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif 2>/dev/null
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif 2>/dev/null
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif 2>/dev/null

# ==========================================
# PART 1: GENERATE CUSTOM LDIFs
# ==========================================
echo ">>> [1] Generating Custom LDIFs..."

HASH_ROOT=$(slappasswd -s "$ROOT_PW_Gw")

cat <<EOF > $LDAP_CONFIG_DIR/1_modify_domain.ldif
dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: $BASE_DN
-
replace: olcRootDN
olcRootDN: cn=admin,$BASE_DN
-
add: olcRootPW
olcRootPW: $HASH_ROOT
-
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange by dn="cn=admin,$BASE_DN" write by anonymous auth by self write by * none
olcAccess: {1}to dn.base="" by * read
olcAccess: {2}to * by dn="cn=admin,$BASE_DN" write by * read
EOF

sed -i "s/dc=if,dc=petra,dc=ac,dc=id/$BASE_DN/g" $LDAP_CONFIG_DIR/2_add_base_domain.ldif

echo "Creating user list..."
cat <<EOF > $LDAP_CONFIG_DIR/3_add_ldap_users.ldif
dn: cn=users,ou=groups,$BASE_DN
objectClass: posixGroup
cn: users
gidNumber: 100
EOF

for USER_ENTRY in "${CUSTOM_USERS[@]}"; do
    IFS=':' read -r UID_NAME CN SN <<< "$USER_ENTRY"
    echo "memberUid: $UID_NAME" >> $LDAP_CONFIG_DIR/3_add_ldap_users.ldif
done

UID_CTR=1100
for USER_ENTRY in "${CUSTOM_USERS[@]}"; do
    IFS=':' read -r UID_NAME CN SN <<< "$USER_ENTRY"
    USER_PASS="login$UID_NAME"
    USER_HASH=$(slappasswd -s "$USER_PASS")

    cat <<EOF >> $LDAP_CONFIG_DIR/3_add_ldap_users.ldif

dn: uid=$UID_NAME,ou=people,$BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: $CN
sn: $SN
userPassword: $USER_HASH
loginShell: /bin/bash
uidNumber: $UID_CTR
gidNumber: 100
homeDirectory: /home/ldap/$UID_NAME
EOF
    ((UID_CTR++))
done

# ==========================================
# PART 2: APPLY CONFIGURATION
# ==========================================
echo ">>> [2] Applying LDAP Config..."

sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f $LDAP_CONFIG_DIR/1_modify_domain.ldif
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f $LDAP_CONFIG_DIR/2_add_base_domain.ldif
sudo ldapadd -Y EXTERNAL -H ldapi:/// -f $LDAP_CONFIG_DIR/3_add_ldap_users.ldif

echo ">>> [2] Updating /etc/openldap/ldap.conf..."
if ! grep -q "URI ldaps://master" /etc/openldap/ldap.conf; then
    echo "URI ldaps://master" | sudo tee -a /etc/openldap/ldap.conf
fi
if ! grep -q "BASE $BASE_DN" /etc/openldap/ldap.conf; then
    echo "BASE $BASE_DN" | sudo tee -a /etc/openldap/ldap.conf
fi

sudo cp $LDAP_CONFIG_DIR/server_*.pem /etc/openldap/certs/
sudo cp $LDAP_CONFIG_DIR/mycacert.crt /etc/openldap/certs/
sudo chmod 600 /etc/openldap/certs/server_key.pem
sudo chown ldap:ldap /etc/openldap/certs/server_*.pem

sudo cp $LDAP_CONFIG_DIR/mycacert.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

ldapmodify -Y EXTERNAL -H ldapi:/// -f $LDAP_CONFIG_DIR/4_modify_ssl.ldif

if grep -q "SLAPD_URLS" /etc/sysconfig/slapd; then
    sudo sed -i 's|.*SLAPD_URLS=.*|SLAPD_URLS="ldapi:/// ldap:/// ldaps:///"|' /etc/sysconfig/slapd
else
    echo 'SLAPD_URLS="ldapi:/// ldap:/// ldaps:///"' | sudo tee -a /etc/sysconfig/slapd
fi

sudo systemctl restart slapd
sleep 2

# ==========================================
# PART 3: MASTER CLIENT SETUP
# ==========================================
echo ">>> [3] Configuring Master Client..."
sudo authconfig --enableldap --enableldaptls --enableldapauth \
--ldapserver="ldaps://master" \
--ldapbasedn="$BASE_DN" \
--enablemkhomedir --update

sudo sed -i 's/^ssl start_tls/#ssl start_tls/' /etc/nslcd.conf
sudo sed -i 's/^tls_cacert /#tls_cacert /' /etc/nslcd.conf
if grep -q "tls_cacertdir" /etc/nslcd.conf; then
    sudo sed -i 's|^tls_cacertdir .*|tls_cacertdir /etc/pki/tls/certs|' /etc/nslcd.conf
else
    echo "tls_cacertdir /etc/pki/tls/certs" | sudo tee -a /etc/nslcd.conf
fi
sudo systemctl enable nscd nslcd
sudo systemctl restart nscd nslcd

# ==========================================
# PART 4: WORKER CLIENT SETUP (Remote)
# ==========================================
echo ">>> [4] Configuring Workers..."

for WORKER in "${WORKER_NODES[@]}"; do
    echo "--- Processing $WORKER ---"
    ssh $SSH_USER@$WORKER "sudo yum -y install openldap-clients nss-pam-ldapd"
    
    ssh $SSH_USER@$WORKER "sudo mkdir -p /etc/openldap/cacerts"
    scp $LDAP_CONFIG_DIR/mycacert.crt $SSH_USER@$WORKER:/tmp/mycacert.crt
    ssh $SSH_USER@$WORKER "sudo mv /tmp/mycacert.crt /etc/openldap/cacerts/"
    
    ssh $SSH_USER@$WORKER "sudo bash -s" <<REMOTE_EOF
    grep -q "URI ldaps://master" /etc/openldap/ldap.conf || echo "URI ldaps://master" >> /etc/openldap/ldap.conf
    grep -q "BASE $BASE_DN" /etc/openldap/ldap.conf || echo "BASE $BASE_DN" >> /etc/openldap/ldap.conf
    grep -q "TLS_CACERT" /etc/openldap/ldap.conf || echo "TLS_CACERT /etc/openldap/cacerts/mycacert.crt" >> /etc/openldap/ldap.conf
    
    authconfig --enableldap --enableldaptls --enableldapauth \
    --ldapserver="ldaps://master" \
    --ldapbasedn="$BASE_DN" \
    --enablemkhomedir --update
    
    sed -i 's/^ssl start_tls/#ssl start_tls/' /etc/nslcd.conf
    sed -i 's/^tls_cacertdir/#tls_cacertdir/' /etc/nslcd.conf
    if grep -q "tls_cacert " /etc/nslcd.conf; then
        sed -i 's|^tls_cacert .*|tls_cacert /etc/openldap/cacerts/mycacert.crt|' /etc/nslcd.conf
    else
        echo "tls_cacert /etc/openldap/cacerts/mycacert.crt" >> /etc/nslcd.conf
    fi
    
    systemctl enable nscd nslcd
    systemctl restart nscd nslcd
REMOTE_EOF
    echo "--- $WORKER Done ---"
done

echo "================================================"
echo "DONE. Verify with: getent passwd tc"
echo "================================================"