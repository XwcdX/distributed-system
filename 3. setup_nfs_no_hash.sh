# ==========================================
# CONFIGURATION
# ==========================================
SSH_USER="ec2-user"
WORKER_NODES=("worker1" "worker2" "worker3" "worker4")

CUSTOM_USERS=(
    "tc"
    "aileen"
    "sharon"
    "kevin"
    "yohan"
)

SCRIPTS_DIR="$HOME/Scripts"
CONFIG_DIR="$HOME/configs"
NFS_CONFIG_DIR="$CONFIG_DIR/nfs"

# ==========================================
# PART 0: PREPARE FILES
# ==========================================
echo ">>> [0] Preparing NFS Config Files..."
mkdir -p $NFS_CONFIG_DIR
if [ -f "$SCRIPTS_DIR/NFS.zip" ]; then
    echo "Unzipping NFS.zip..."
    unzip -o -q "$SCRIPTS_DIR/NFS.zip" -d $NFS_CONFIG_DIR
    
    [ -d "$NFS_CONFIG_DIR/NFS" ] && mv $NFS_CONFIG_DIR/NFS/* $NFS_CONFIG_DIR/ && rmdir $NFS_CONFIG_DIR/NFS
else
    echo "ERROR: NFS.zip not found in $SCRIPTS_DIR!"
    exit 1
fi

# ==========================================
# PART 1: MASTER SERVER SETUP
# ==========================================
echo ">>> [1] Configuring Master NFS Server..."
sudo yum install -y nfs-utils

MASTER_IP=$(hostname -I | awk '{print $1}')
SUBNET=$(echo $MASTER_IP | cut -d'.' -f1-3).0/29
echo "Detected Subnet for Exports: $SUBNET"

echo "/home/ldap $SUBNET(rw,no_subtree_check,no_root_squash)" > $NFS_CONFIG_DIR/_etc_exports

sudo cp $NFS_CONFIG_DIR/_etc_exports /etc/exports
sudo cp $NFS_CONFIG_DIR/_etc_sysconfig_nfs /etc/sysconfig/nfs
sudo cp $NFS_CONFIG_DIR/_etc_sysctl.conf /etc/sysctl.conf

echo ">>> [1] Restarting Services to apply sysctl ports..."
sudo sysctl --system
sudo systemctl restart nfs-utils

sudo systemctl enable nfs-server
sudo systemctl start nfs-server

sudo systemctl stop nfs-server.service nfs-mountd.service nfs-idmapd.service nfs-utils.service rpc-statd.service rpc_pipefs.target rpcbind.socket

sudo sysctl --system
sudo systemctl restart nfs-utils
sudo systemctl start rpcbind nfs-server

echo "Master NFS Status:"
systemctl status nfs-server | grep Active

# ==========================================
# PART 2: WORKER SETUP (Remote)
# ==========================================
echo ">>> [2] Configuring Workers..."
for WORKER in "${WORKER_NODES[@]}"; do
    echo "--- Mounting NFS on $WORKER ---"
    
    ssh $SSH_USER@$WORKER "sudo bash -s" <<REMOTE_EOF
    
    yum install -y nfs-utils
    
    mkdir -p /home/ldap

    if ! grep -q "master:/home/ldap" /etc/fstab; then
        echo -e "master:/home/ldap\t/home/ldap\tnfs4\tnoauto\t0 0" >> /etc/fstab
    fi
    
    mount /home/ldap
    
    df -h | grep ldap
REMOTE_EOF

    echo "--- $WORKER Done ---"
done

# ==========================================
# PART 3: GENERATE SSH KEYS FOR USERS
# ==========================================
TEMP_KNOWN_HOSTS="/tmp/cluster_known_hosts"
> $TEMP_KNOWN_HOSTS

echo ">>> [3] Generating SSH Keys for LDAP Users..."
ALL_NODES=("master" "${WORKER_NODES[@]}")

for NODE in "${ALL_NODES[@]}"; do
    NODE_IP=$(grep -w "$NODE" /etc/hosts | awk '{print $1}')
    
    if [ ! -z "$NODE_IP" ]; then
        echo "   Adding $NODE ($NODE_IP)..."
        ssh-keyscan $NODE_IP 2>/dev/null | sed "s/^$NODE_IP/$NODE,$NODE_IP/" >> $TEMP_KNOWN_HOSTS
    fi
done

for USER_NAME in "${CUSTOM_USERS[@]}"; do
    U_NAME=$(echo $USER_NAME | cut -d: -f1)
    
    echo "Processing User: $U_NAME"

    sudo su - $U_NAME -c "bash -c '
        if [ ! -f ~/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -b 4096 -f ~/.ssh/id_ed25519 -N \"\" -q
        fi
        
        cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
    '"

    sudo cp $TEMP_KNOWN_HOSTS /home/ldap/$U_NAME/.ssh/known_hosts
    sudo chown $U_NAME: /home/ldap/$U_NAME/.ssh/known_hosts
    sudo chmod 644 /home/ldap/$U_NAME/.ssh/known_hosts
done

sudo rm $TEMP_KNOWN_HOSTS

echo "================================================"
echo "NFS & USER KEY SETUP COMPLETE"
echo "Test: su - tc"
echo "Then: ssh worker1 (should not ask for password)"
echo "Check file share: touch testfile on master, check on worker"
echo "================================================"