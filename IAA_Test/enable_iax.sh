for ((i=1;$i<=15;i=$i+2))
do
        echo $i
 
        accel-config config-engine iax$i/engine$i.0 -g 0
        accel-config config-engine iax$i/engine$i.1 -g 0
        accel-config config-engine iax$i/engine$i.2 -g 0
        accel-config config-engine iax$i/engine$i.3 -g 0
        accel-config config-engine iax$i/engine$i.4 -g 0
        accel-config config-engine iax$i/engine$i.5 -g 0
        accel-config config-engine iax$i/engine$i.6 -g 0
        accel-config config-engine iax$i/engine$i.7 -g 0
        
 
 
        accel-config config-wq iax$i/wq$i.0 -g 0 -s 128 -p 10 -b 1 -t 128  -m shared -y user -n iax_crypto
       # accel-config config-wq iax$i/wq$i.1 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.2 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.3 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.4 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.5 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.6 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
       # accel-config config-wq iax$i/wq$i.7 -g 0 -s 16 -p 10 -b 1 -t 15 -m shared -y user -n app1
 
        accel-config enable-device iax$i
 
        accel-config enable-wq iax$i/wq$i.0
       # accel-config enable-wq iax$i/wq$i.1
       # accel-config enable-wq iax$i/wq$i.2
       # accel-config enable-wq iax$i/wq$i.3
       # accel-config enable-wq iax$i/wq$i.4
       # accel-config enable-wq iax$i/wq$i.5
       # accel-config enable-wq iax$i/wq$i.6
       # accel-config enable-wq iax$i/wq$i.7
done
