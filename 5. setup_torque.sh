# ==========================================
# CONFIGURATION
# ==========================================
SSH_USER="ec2-user"
BENCHMARK_USER="tc"
WORKER_NODES=("worker1" "worker2" "worker3" "worker4")
ALL_NODES=("master" "worker1" "worker2" "worker3" "worker4")

MPI_BIN="/usr/lib64/openmpi/bin"
MPI_EXEC="$MPI_BIN/mpiexec"

# ==========================================
# PART 1: MASTER INSTALLATION (Server)
# ==========================================
echo ">>> [1] Installing TORQUE on Master..."

sudo amazon-linux-extras install epel -y
sudo yum install -y torque torque-server torque-client torque-scheduler torque-mom

echo ">>> [1] Configuring Munge..."
if [ ! -f /etc/munge/munge.key ]; then
    sudo create-munge-key
fi
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
sudo systemctl enable munge
sudo systemctl start munge

echo ">>> [1] Distributing Munge Key to Workers..."
for HOST in "${WORKER_NODES[@]}"; do
    echo "Sending key to $HOST..."
    sudo cat /etc/munge/munge.key | ssh $SSH_USER@$HOST "sudo tee /etc/munge/munge.key > /dev/null"
done

echo ">>> [1] Verifying Munge Communication..."
unmunge_result=$(munge -n | ssh ${WORKER_NODES[0]} unmunge 2>&1)
if [[ $unmunge_result == *"Success"* ]]; then
    echo "Munge Check: SUCCESS"
else
    echo "Munge Check: WARNING (Check logs if jobs fail)"
fi

# ==========================================
# PART 2: CONFIGURE MASTER TORQUE
# ==========================================
echo ">>> [2] Configuring Master Torque..."

echo "master" | sudo tee /etc/torque/server_name

echo "\$pbsserver master" | sudo tee /etc/torque/mom/config
echo "\$logevent 0x0ff" | sudo tee -a /etc/torque/mom/config

if [ -f /usr/share/doc/torque-4.2.10/torque.setup ]; then
    sudo bash /usr/share/doc/torque-4.2.10/torque.setup root master
fi

echo "Stopping manual Torque processes..."
sudo pkill pbs_server
sudo pkill trqauthd
sudo pkill -9 pbs_server 2>/dev/null
sudo pkill -9 trqauthd 2>/dev/null

echo "Generating /var/lib/torque/server_priv/nodes..."
sudo truncate -s 0 /var/lib/torque/server_priv/nodes
for NODE in "${ALL_NODES[@]}"; do
    echo "$NODE np=2 num_node_boards=1" | sudo tee -a /var/lib/torque/server_priv/nodes
done

sudo systemctl enable pbs_server pbs_sched pbs_mom trqauthd

# ==========================================
# PART 3: WORKER INSTALLATION (Remote)
# ==========================================
echo ">>> [3] Configuring Workers..."

for WORKER in "${WORKER_NODES[@]}"; do
    echo "--- Setup Torque on $WORKER ---"
    
    ssh $SSH_USER@$WORKER "sudo bash -s" <<REMOTE_EOF
    
    amazon-linux-extras install epel -y
    yum install -y torque torque-mom
    
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
    systemctl enable munge
    systemctl restart munge
    
    echo "master" > /etc/torque/server_name
    echo "\$pbsserver master" > /etc/torque/mom/config
    echo "\$logevent 0x0ff" >> /etc/torque/mom/config
    
    systemctl enable pbs_mom trqauthd
    systemctl restart pbs_mom trqauthd
    
    systemctl is-active pbs_mom > /dev/null && echo "MOM Active" || echo "MOM Failed"
REMOTE_EOF
done

# ==========================================
# PART 4: START MASTER SERVICES & QUEUE
# ==========================================
echo ">>> [4] Starting Master Services..."

sudo systemctl start pbs_mom
sudo systemctl restart pbs_server
sudo systemctl start pbs_sched trqauthd

sleep 5

echo "Configuring Queue..."
sudo qmgr -c "set server scheduling = true"
sudo qmgr -c "create queue batch queue_type = execution"
sudo qmgr -c "set queue batch started = true"
sudo qmgr -c "set queue batch enabled = true"
sudo qmgr -c "set queue batch resources_default.nodes = 1"
sudo qmgr -c "set queue batch resources_default.walltime = 01:00:00"
sudo qmgr -c "set server default_queue = batch"

echo "------------------------------------------------"
echo "Print Queue Batch (p q batch):"
sudo qmgr -c 'p q batch'
echo "------------------------------------------------"
echo "Check Nodes (pbsnodes):"
pbsnodes -l
echo "------------------------------------------------"

# ==========================================
# PART 5: USER JOB SETUP (User: tc)
# ==========================================
echo ">>> [5] Generating PBS Scripts for user: $BENCHMARK_USER..."

sudo su - $BENCHMARK_USER -c "bash -s" <<USER_EOF

mkdir -p ~/pbs
mkdir -p ~/test

cat <<PBS_TEST > ~/test/test.sh
#!/bin/bash
#PBS -N test_job
#PBS -l walltime=00:01:00
#PBS -l nodes=2:ppn=1
#PBS -q batch

echo "Running on:"
cat \$PBS_NODEFILE
/usr/lib64/openmpi/bin/mpiexec -np 2 --hostfile \$PBS_NODEFILE /bin/hostname
PBS_TEST

generate_pbs() {
    CORES=\$1
    NODES=\$2
    
    cat <<PBS_FILE > ~/pbs/hpcc-n\${CORES}.sh
#!/bin/bash
#PBS -N job.hpcc-n\${CORES}
#PBS -l walltime=00:10:00
#PBS -l nodes=\${NODES}:ppn=2
#PBS -q batch

cd /home/ldap/$BENCHMARK_USER/hpcc-n\${CORES}
echo "Starting HPCC n\${CORES}..."
/usr/lib64/openmpi/bin/mpiexec -np \${CORES} --hostfile \$PBS_NODEFILE /opt/share/hpcc
PBS_FILE
}

generate_pbs 2 1
generate_pbs 4 2
generate_pbs 6 3
generate_pbs 8 4
generate_pbs 10 5

echo "PBS Scripts generated in ~/pbs/"
ls -l ~/pbs/

echo "Cleaning old hpccoutf.txt files..."
rm -f ~/hpcc-n*/hpccoutf.txt

USER_EOF

echo "================================================"
echo "TORQUE SETUP COMPLETE"
echo "1. Switch user: su - tc"
echo "2. Go to folder: cd ~/pbs"
echo "3. Submit job: qsub hpcc-n10.sh"
echo "4. Check status: qstat -n"
echo "================================================"