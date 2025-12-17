# ==========================================
# CONFIGURATION
# ==========================================
SSH_USER="ec2-user"
BENCHMARK_USER="tc"
WORKER_NODES=("worker1" "worker2" "worker3" "worker4")

SCRIPTS_DIR="$HOME/Scripts"
CONFIG_DIR="$HOME/configs"
HPCC_CONFIG_DIR="$CONFIG_DIR/hpcc"
HPCC_SOURCE_DIR="$HOME/hpcc-1.5.0"
SHARED_DIR="/opt/share"

MPI_BIN="/usr/lib64/openmpi/bin"
MPI_EXEC="$MPI_BIN/mpiexec"

# ==========================================
# PART 0: PREPARE FILES
# ==========================================
echo ">>> [0] Preparing HPCC Config Files..."
mkdir -p $HPCC_CONFIG_DIR
if [ -f "$SCRIPTS_DIR/HPCC.zip" ]; then
    echo "Unzipping HPCC.zip..."
    unzip -o -q "$SCRIPTS_DIR/HPCC.zip" -d $HPCC_CONFIG_DIR

    [ -d "$HPCC_CONFIG_DIR/HPCC" ] && mv $HPCC_CONFIG_DIR/HPCC/* $HPCC_CONFIG_DIR/ && rmdir $HPCC_CONFIG_DIR/HPCC
else
    echo "ERROR: HPCC.zip not found in $SCRIPTS_DIR!"
    exit 1
fi

# ==========================================
# PART 1: MASTER INSTALLATION & COMPILATION
# ==========================================
echo ">>> [1] Installing Dependencies on Master..."
sudo yum install -y openmpi-devel atlas-devel blas-devel gcc-gfortran

echo ">>> [1] Downloading HPCC..."
cd $HOME
if [ ! -f "hpcc-1.5.0.tar.gz" ]; then
    wget -q http://icl.cs.utk.edu/projectsfiles/hpcc/download/hpcc-1.5.0.tar.gz
fi

echo ">>> [1] Extracting..."
tar -xzvf hpcc-1.5.0.tar.gz > /dev/null
rm -f hpcc-1.5.0.tar.gz

echo ">>> [1] Configuring Makefile..."
cp $HPCC_CONFIG_DIR/Make.Linux_PII_CBLAS $HPCC_SOURCE_DIR/hpl/

echo ">>> [1] Compiling HPCC (This may take a minute)..."
cd $HPCC_SOURCE_DIR
export PATH=$PATH:$MPI_BIN
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib64/openmpi/lib

make arch=Linux_PII_CBLAS

if [ ! -f "hpcc" ]; then
    echo "ERROR: Compilation failed. 'hpcc' binary not created."
    exit 1
fi

# ==========================================
# PART 2: SETUP SHARED FOLDER (/opt/share)
# ==========================================
echo ">>> [2] Setting up /opt/share..."
sudo mkdir -p $SHARED_DIR

sudo cp $HPCC_SOURCE_DIR/hpcc $SHARED_DIR/
sudo cp $HPCC_SOURCE_DIR/_hpccinf.txt $SHARED_DIR/

MASTER_IP=$(hostname -I | awk '{print $1}')
SUBNET=$(python3 -c "import ipaddress; print(ipaddress.IPv4Interface('$MASTER_IP/29').network)")

echo ">>> [2] Exporting /opt/share to $SUBNET..."
if ! grep -q "/opt/share" /etc/exports; then
    echo "/opt/share $SUBNET(rw,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
    sudo exportfs -r
else
    echo "/opt/share already exported."
fi

sudo systemctl restart nfs-server

# ==========================================
# PART 3: SETUP WORKERS
# ==========================================
echo ">>> [3] Configuring Workers..."
for WORKER in "${WORKER_NODES[@]}"; do
    echo "--- Setup $WORKER ---"
    ssh $SSH_USER@$WORKER "sudo bash -s" <<REMOTE_EOF
    yum install -y openmpi atlas blas
    
    mkdir -p /opt/share

    if ! grep -q "master:/opt/share" /etc/fstab; then
        echo -e "master:/opt/share\t/opt/share\tnfs4\tnoauto\t0 0" >> /etc/fstab
    fi

    mount /opt/share

    ls /opt/share/hpcc > /dev/null && echo "Mount Success" || echo "Mount Failed"
REMOTE_EOF
done

# ==========================================
# PART 4: USER BENCHMARK SETUP (User: tc)
# ==========================================
echo ">>> [4] Setting up Benchmarks for user: $BENCHMARK_USER..."
sudo su - $BENCHMARK_USER -c "bash -s" <<USER_EOF

module load mpi/openmpi-x86_64
ABSOLUTE_MPI=\$(which mpiexec)
echo "MPI Path detected: \$ABSOLUTE_MPI"

if [ -z "\$ABSOLUTE_MPI" ]; then
    ABSOLUTE_MPI=$MPI_EXEC
fi
echo "Using MPI: \$ABSOLUTE_MPI"

# 3. Create Folders
mkdir -p ~/hpcc-n{2,4,6,8,10}

# 4. Copy Configs & Edit P/Q
# Logic: P * Q = N (Total Cores)

# --- 2 Cores (P=2, Q=1) ---
cp /opt/share/_hpccinf.txt ~/hpcc-n2/hpccinf.txt
sed -i 's/^[0-9]* *Ps/2            Ps/' ~/hpcc-n2/hpccinf.txt
sed -i 's/^[0-9]* *Qs/1            Qs/' ~/hpcc-n2/hpccinf.txt

# --- 4 Cores (P=2, Q=2) ---
cp /opt/share/_hpccinf.txt ~/hpcc-n4/hpccinf.txt
sed -i 's/^[0-9]* *Ps/2            Ps/' ~/hpcc-n4/hpccinf.txt
sed -i 's/^[0-9]* *Qs/2            Qs/' ~/hpcc-n4/hpccinf.txt

# --- 6 Cores (P=3, Q=2) ---
cp /opt/share/_hpccinf.txt ~/hpcc-n6/hpccinf.txt
sed -i 's/^[0-9]* *Ps/3            Ps/' ~/hpcc-n6/hpccinf.txt
sed -i 's/^[0-9]* *Qs/2            Qs/' ~/hpcc-n6/hpccinf.txt

# --- 8 Cores (P=4, Q=2) ---
cp /opt/share/_hpccinf.txt ~/hpcc-n8/hpccinf.txt
sed -i 's/^[0-9]* *Ps/4            Ps/' ~/hpcc-n8/hpccinf.txt
sed -i 's/^[0-9]* *Qs/2            Qs/' ~/hpcc-n8/hpccinf.txt

# --- 10 Cores (P=5, Q=2) ---
cp /opt/share/_hpccinf.txt ~/hpcc-n10/hpccinf.txt
sed -i 's/^[0-9]* *Ps/5            Ps/' ~/hpcc-n10/hpccinf.txt
sed -i 's/^[0-9]* *Qs/2            Qs/' ~/hpcc-n10/hpccinf.txt

echo "Benchmark Folders Created."

# ==========================================
# CREATE RUNNER SCRIPT
# ==========================================
cat <<RUN_SCRIPT > ~/run_benchmarks.sh
#!/bin/bash
module load mpi/openmpi-x86_64
MPI_CMD="\$ABSOLUTE_MPI"
HPCC_BIN="/opt/share/hpcc"

echo "=== RUNNING 2 CORES (Master) ==="
cd ~/hpcc-n2 && \$MPI_CMD -n 2 --host master:2 \$HPCC_BIN

echo "=== RUNNING 4 CORES (Master + W1) ==="
cd ~/hpcc-n4 && \$MPI_CMD -n 4 --host master:2,worker1:2 \$HPCC_BIN

echo "=== RUNNING 6 CORES (M + W1 + W2) ==="
cd ~/hpcc-n6 && \$MPI_CMD -n 6 --host master:2,worker1:2,worker2:2 \$HPCC_BIN

echo "=== RUNNING 8 CORES (M + W1 + W2 + W3) ==="
cd ~/hpcc-n8 && \$MPI_CMD -n 8 --host master:2,worker1:2,worker2:2,worker3:2 \$HPCC_BIN

echo "=== RUNNING 10 CORES (All Nodes) ==="
cd ~/hpcc-n10 && \$MPI_CMD -n 10 --host master:2,worker1:2,worker2:2,worker3:2,worker4:2 \$HPCC_BIN

echo "ALL BENCHMARKS FINISHED."
RUN_SCRIPT

chmod +x ~/run_benchmarks.sh
USER_EOF

echo "================================================"
echo "HPCC SETUP COMPLETE"
echo "To run the benchmarks:"
echo "1. su - tc"
echo "2. ./run_benchmarks.sh"
echo "================================================"