import os
import sys
import time
import paramiko

IPHONE_IP = "192.168.1.23"
IPHONE_PORT = 1234
SSH_USER = "mobile"
SSH_PASS = "1"

def deploy():
    deb_path = os.path.abspath("packages/ACBFace_1.0.0_roothide.deb")
    if not os.path.exists(deb_path):
        deb_path = os.path.abspath("packages/ACBFace_1.0.0_rootful.deb")
    
    print(f"Deploying: {deb_path} ({os.path.getsize(deb_path)} bytes)")
    
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(IPHONE_IP, port=IPHONE_PORT, username=SSH_USER, password=SSH_PASS, timeout=10)
    print("Connected to iPhone via SSH!")
    
    # 1. SFTP Upload
    sftp = client.open_sftp()
    remote_deb = "/var/mobile/ACBFace_latest.deb"
    sftp.put(deb_path, remote_deb)
    sftp.close()
    print("Uploaded package to iPhone:", remote_deb)
    
    # 2. DPKG Install
    stdin, stdout, stderr = client.exec_command(f"echo {SSH_PASS} | sudo -S dpkg -i {remote_deb}")
    out = stdout.read().decode('utf-8', 'ignore')
    print("DPKG INSTALL RESULT:\n", out)
    
    # 3. Verify Binary MD5 & Entitlements
    stdin, stdout, stderr = client.exec_command("md5sum /Applications/ACBFace.app/ACBFace || md5 /Applications/ACBFace.app/ACBFace")
    print("INSTALLED BINARY MD5:", stdout.read().decode('utf-8', 'ignore').strip())
    
    stdin, stdout, stderr = client.exec_command("ldid -e /Applications/ACBFace.app/ACBFace 2>&1")
    ent = stdout.read().decode('utf-8', 'ignore')
    if "kTCCServiceCamera" in ent:
        print("[OK] Verified: kTCCServiceCamera entitlement is PRESENT!")
    else:
        print("[WARN] Entitlement output:\n", ent[:300])
        
    # 4. Relaunch app
    client.exec_command(f"echo {SSH_PASS} | sudo -S killall -9 ACBFace 2>/dev/null")
    time.sleep(1)
    
    stdin, stdout, stderr = client.exec_command("export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:$PATH; uiopen --bundleid com.client.acbface")
    print("LAUNCH OUTPUT:", stdout.read().decode('utf-8', 'ignore').strip())
    
    time.sleep(2)
    stdin, stdout, stderr = client.exec_command(f"echo {SSH_PASS} | sudo -S killall -0 ACBFace 2>/dev/null && echo 'ACBFace is RUNNING' || echo 'ACBFace is NOT running'")
    print("STATUS:", stdout.read().decode('utf-8', 'ignore').strip())
    
    client.close()
    print("=== DEPLOYMENT COMPLETED SUCCESSFULLY ===")

if __name__ == '__main__':
    deploy()
