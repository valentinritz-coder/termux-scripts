su -c 'mkdir -p /data/adb/service.d'
su -c 'cat > /data/adb/service.d/90-adbd-tcp.sh << "EOF"
#!/system/bin/sh
setprop service.adb.tcp.port 5555
setprop ctl.restart adbd
EOF'
su -c 'chmod 755 /data/adb/service.d/90-adbd-tcp.sh'
