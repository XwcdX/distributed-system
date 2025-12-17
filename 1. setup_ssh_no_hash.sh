SSH_USER="ec2-user"

MY_SKELETON_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC3KXeI5FmzToKvu1c++73P3k2uGV+emfBxFgC9aTSAG/TwHJCgZlApkkY34j46Ts9ZUE+RJ7cSssHqEigrVbPa1fB4cKu5A6CZ3EarO0V7N1McZytDQxeL2c1P5nUZqR6nlJ+0oBJ3MP1M/80Kowrufh32ZXA181MHLOMilOOh9fJ+lnYMgr9Geu9kKF+VgiSAfim/6r/h43KXp0GZbsHMrf03Ecu6sdnJFXA7UngTujmKKuTC56IZXsi0lJQLYKNVJBoPRDUKzxSAjB17f/v963vFsmH2wP7juGT0mIDRK/agsVGdy8ZOFE7YdwcIZ0CC9r1eu3/9b2J/tBwA+6pGThUMebjftB/DRy/iMfBWcTDI4PDKNPGWSO4m0PWxmCDrlLxz3QnldADPbmFp86yHCUIlQke1tj3KE7dghg+wYjE8AEz9FTAB/HxySnfC9QoHambMZdpr65BgdyTswNqRy6oSe06sA/+UzlnWwcAqKdUR0g5Z6ROyffBQtF1wH2gbIcphexmNMsqEBYwTbHOfPbEd2i3nDyQzMh+4QE1BIS40Oo6vbCf4x983fZubLSUcNMUGGstKvg5/aACdJ3yMZdlfDxAE4edM3AlX8sf05invizR1f75SE2A4mgIM0eWvDD/+LNc45diMFuznOETvwgEuCfWlHx3KIwaMqBprbQ== skeletonpuppet90@gmail.com"

# ==========================================
# STEP 1: COLLECT IPs
# ==========================================
echo "------------------------------------------------"
echo "Please enter the Private IPs."
echo "Ensure Master can already SSH to Workers (1 hop)!"
echo "------------------------------------------------"

read -p "Enter MASTER IP: " IP_MASTER
read -p "Enter WORKER 1 IP: " IP_W1
read -p "Enter WORKER 2 IP: " IP_W2
read -p "Enter WORKER 3 IP: " IP_W3
read -p "Enter WORKER 4 IP: " IP_W4

ALL_IPS=($IP_MASTER $IP_W1 $IP_W2 $IP_W3 $IP_W4)
ALL_NAMES=("master" "worker1" "worker2" "worker3" "worker4")

WORKER_IPS=($IP_W1 $IP_W2 $IP_W3 $IP_W4)
WORKER_NAMES=("worker1" "worker2" "worker3" "worker4")

# ==========================================
# STEP 2: PREPARE FILES
# ==========================================
HOSTS_CONTENT=$(cat <<EOF
127.0.0.1 localhost
$IP_MASTER master
$IP_W1 worker1
$IP_W2 worker2
$IP_W3 worker3
$IP_W4 worker4
EOF
)

# ==========================================
# STEP 3: MASTER CONFIGURATION
# ==========================================
echo ">>> Configuring MASTER..."
echo "$HOSTS_CONTENT" | sudo tee /etc/hosts > /dev/null
sudo hostnamectl set-hostname master

if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating new SSH key..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
fi

cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
echo "$MY_SKELETON_KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "Scanning network to populate known_hosts..."
for i in {0..4}; do
    SCAN_IP=${ALL_IPS[$i]}
    SCAN_NAME=${ALL_NAMES[$i]}
    
    echo "   Scanning $SCAN_NAME ($SCAN_IP)..."
    ssh-keyscan $SCAN_IP 2>/dev/null | sed "s/^$SCAN_IP/$SCAN_NAME,$SCAN_IP/" >> ~/.ssh/known_hosts
done

echo ">>> Master Configured."

# ==========================================
# STEP 4: DISTRIBUTE TO WORKERS
# ==========================================
for i in {0..3}; do
    CURRENT_IP=${WORKER_IPS[$i]}
    CURRENT_NAME=${WORKER_NAMES[$i]}
    echo "------------------------------------------------"
    echo ">>> Processing $CURRENT_NAME ($CURRENT_IP)..."
    
    scp -r ~/.ssh/* $SSH_USER@$CURRENT_IP:~/.ssh/
    
    ssh $SSH_USER@$CURRENT_IP << EOF
        sudo hostnamectl set-hostname $CURRENT_NAME
        echo "$HOSTS_CONTENT" | sudo tee /etc/hosts > /dev/null
        
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys
        if [ -f ~/.ssh/id_ed25519 ]; then
            chmod 600 ~/.ssh/id_ed25519
        fi
        chmod 644 ~/.ssh/known_hosts
EOF

    echo ">>> $CURRENT_NAME Done."
done

echo "================================================"
echo "CLUSTER READY"
echo "================================================"