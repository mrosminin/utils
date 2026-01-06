# сравнение скорости записи на диск
sudo dd if=/dev/zero of=/passages2/.dd_test bs=16M count=64 oflag=direct status=progress
sync
sudo rm -f /passages2/.dd_test

sudo dd if=/dev/zero of=/passages/.dd_test bs=16M count=16 oflag=direct status=progress
sync
sudo rm -f /passages/.dd_test

# проверка живости minio
curl -m 2 -sS -o /dev/null -w 'http=%{http_code} time=%{time_total}\n' http://10.1.104.74:9000/minio/health/live

# скорость удаления
t=10
a=$(df -B1 /passages | awk 'END{print $4}')
sleep $t
b=$(df -B1 /passages | awk 'END{print $4}')
awk -v d=$((b-a)) -v t=$t 'BEGIN {printf "freeing: %.2f MiB/s\n", d/1024/1024/t}'

# живой монитор
watch -n 10 'df -h /passages; echo; df -BM /passages | tail -1'

# монитор iostat - нагрузка на диск
sudo iostat -xm 1 10 | egrep 'avg-cpu|Device|sdc'


