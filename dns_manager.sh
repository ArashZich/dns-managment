#!/bin/bash

# تنظیمات اولیه
DNS_SET_1=("185.51.200.2" "178.22.122.100")  # شبکه ملی
DNS_SET_2=("78.157.42.101" "78.157.42.100")  # DNS ایرانسل
DNS_SET_3=("8.8.8.8" "8.8.4.4")              # DNS گوگل
DNS_SET_4=("1.1.1.1" "1.0.0.1")              # DNS کلودفلر
RESOLV_CONF="/etc/resolv.conf"
BACKUP_FILE="/etc/resolv.conf.backup"

# پیدا کردن اینترفیس فعال به صورت اتوماتیک
ACTIVE_INTERFACE=$(ip route | grep default | awk '{print $5}')

# بررسی دسترسی سودو
if [ "$(id -u)" -ne 0 ]; then
    echo "این اسکریپت نیاز به دسترسی root دارد. لطفاً با sudo اجرا کنید."
    echo "مثال: sudo $0 dns1"
    exit 1
fi

# بررسی وجود اینترفیس
if [ -z "$ACTIVE_INTERFACE" ]; then
    echo "هیچ اینترفیس فعالی پیدا نشد. لطفاً اتصال شبکه خود را بررسی کنید."
    exit 1
fi

echo "اینترفیس فعال: $ACTIVE_INTERFACE"

# ذخیره DNS اولیه اگر بکاپ وجود نداشته باشد
function save_default_dns() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "ذخیره تنظیمات اولیه DNS..."
        sudo cp $RESOLV_CONF $BACKUP_FILE
        echo "بکاپ از تنظیمات اولیه DNS ایجاد شد."
    fi
}

# بازگرداندن تنظیمات از بکاپ
function restore_backup() {
    if [ -f "$BACKUP_FILE" ]; then
        echo "بازگرداندن تنظیمات اولیه DNS..."
        
        if systemctl is-active --quiet systemd-resolved; then
            # متوقف کردن systemd-resolved برای تنظیم مجدد
            sudo systemctl stop systemd-resolved
            
            # کپی فایل بکاپ
            sudo cp $BACKUP_FILE $RESOLV_CONF
            
            # راه‌اندازی مجدد systemd-resolved
            sudo systemctl start systemd-resolved
            
            # بازیابی تنظیمات DNS از فایل بکاپ
            DEFAULT_DNS=$(grep "nameserver" $BACKUP_FILE | awk '{print $2}')
            
            # پاک کردن DNS های فعلی
            sudo resolvectl dns $ACTIVE_INTERFACE
            
            # تنظیم DNS های پیش فرض
            for dns in $DEFAULT_DNS; do
                sudo resolvectl dns $ACTIVE_INTERFACE $dns
            done
            
            sudo resolvectl domain $ACTIVE_INTERFACE '~.'
            sudo resolvectl flush-caches
            echo "تنظیمات اولیه DNS در systemd-resolved بازیابی شد."
        else
            sudo cp $BACKUP_FILE $RESOLV_CONF
            echo "تنظیمات اولیه DNS بازیابی شد."
        fi
        
        # راه‌اندازی مجدد شبکه
        restart_network
    else
        echo "هیچ بکاپی یافت نشد!"
    fi
}

# تنظیم DNS
function set_dns() {
    local dns_servers=("$@")
    
    # ذخیره تنظیمات اولیه اگر وجود ندارد
    save_default_dns
    
    echo "تنظیم DNS به: ${dns_servers[*]}"
    
    if systemctl is-active --quiet systemd-resolved; then
        echo "systemd-resolved شناسایی شد. در حال تنظیم DNS روی اینترفیس $ACTIVE_INTERFACE..."
        
        # غیرفعال کردن موقت systemd-resolved تا بتوانیم DNS را درست تنظیم کنیم
        systemctl stop systemd-resolved
        
        # تغییر فایل resolv.conf
        rm -f $RESOLV_CONF
        for dns in "${dns_servers[@]}"; do
            echo "nameserver $dns" | tee -a $RESOLV_CONF > /dev/null
        done
        
        # راه‌اندازی مجدد systemd-resolved
        systemctl start systemd-resolved
        
        # اطمینان از اعمال DNS‌های جدید
        for dns in "${dns_servers[@]}"; do
            resolvectl dns $ACTIVE_INTERFACE $dns
        done
        
        resolvectl domain $ACTIVE_INTERFACE '~.'
        resolvectl flush-caches
        echo "DNS در systemd-resolved بروزرسانی شد."
    else
        # بکاپ از فایل resolv.conf
        sudo cp $RESOLV_CONF ${RESOLV_CONF}.tmp
        
        # حذف nameserver‌های قبلی و اضافه کردن جدید
        sudo grep -v "^nameserver" ${RESOLV_CONF}.tmp | sudo tee $RESOLV_CONF > /dev/null
        
        for dns in "${dns_servers[@]}"; do
            echo "nameserver $dns" | sudo tee -a $RESOLV_CONF > /dev/null
        done
        
        sudo rm ${RESOLV_CONF}.tmp
        echo "DNS بروزرسانی شد به: ${dns_servers[*]}"
    fi
    
    # راه‌اندازی مجدد شبکه
    restart_network
}

# راه‌اندازی مجدد شبکه
function restart_network() {
    echo "در حال راه‌اندازی مجدد اینترفیس شبکه..."
    
    # فلاش کردن DNS کش سیستم
    if command -v systemd-resolve &> /dev/null; then
        sudo systemd-resolve --flush-caches
    fi
    
    if command -v nmcli &> /dev/null; then
        # اگر از NetworkManager استفاده می‌شود
        sudo nmcli connection down "$ACTIVE_INTERFACE" 2>/dev/null || true
        sleep 2
        sudo nmcli connection up "$ACTIVE_INTERFACE" 2>/dev/null || true
        
        # در صورت شکست، کل نتورک را ریست می‌کنیم
        if [ $? -ne 0 ]; then
            sudo nmcli networking off
            sleep 2
            sudo nmcli networking on
        fi
    else
        # اگر از systemd استفاده می‌شود
        sudo ip link set "$ACTIVE_INTERFACE" down
        sleep 2
        sudo ip link set "$ACTIVE_INTERFACE" up
    fi
    
    echo "شبکه مجدداً راه‌اندازی شد."
    sleep 3  # کمی صبر می‌کنیم تا شبکه کاملاً راه‌اندازی شود
}

# نمایش وضعیت فعلی DNS
function show_status() {
    echo "وضعیت فعلی DNS:"
    if systemctl is-active --quiet systemd-resolved; then
        echo "DNS در systemd-resolved (برای اینترفیس $ACTIVE_INTERFACE):"
        resolvectl dns $ACTIVE_INTERFACE
        
        # همچنین نمایش DNS های فعلی از فایل resolv.conf
        echo -e "\nDNS در /etc/resolv.conf:"
        grep "nameserver" $RESOLV_CONF 2>/dev/null || echo "هیچ DNS در فایل resolv.conf تنظیم نشده است."
        
        echo -e "\nبرای آزمایش DNS فعلی می‌توانید از دستور زیر استفاده کنید:"
        echo "nslookup google.com"
    else
        echo "DNS در /etc/resolv.conf:"
        grep "nameserver" $RESOLV_CONF || echo "هیچ DNS تنظیم نشده است."
    fi
}

# راهنما
function show_help() {
    echo "استفاده: $0 {dns1|dns2|dns3|dns4|reset|status|help}"
    echo ""
    echo "گزینه‌ها:"
    echo "  dns1   : تنظیم DNS شبکه ملی (${DNS_SET_1[*]})"
    echo "  dns2   : تنظیم DNS ایرانسل (${DNS_SET_2[*]})"
    echo "  dns3   : تنظیم DNS گوگل (${DNS_SET_3[*]})"
    echo "  dns4   : تنظیم DNS کلودفلر (${DNS_SET_4[*]})"
    echo "  reset  : بازگشت به تنظیمات اولیه DNS"
    echo "  status : نمایش وضعیت فعلی DNS"
    echo "  help   : نمایش این راهنما"
    echo ""
    echo "توجه: به دلایل امنیتی، برخی سایت‌ها با DNS شبکه ملی ممکن است باز نشوند."
    echo "      در این صورت از dns3 یا dns4 استفاده کنید."
}

# بررسی آرگومان‌ها
case "$1" in
    "dns1")
        set_dns "${DNS_SET_1[@]}"
        sleep 2 # کمی صبر می‌کنیم تا تغییرات اعمال شود
        show_status
        echo -e "\nتوجه: برخی سایت‌ها با DNS شبکه ملی ممکن است خطای امنیتی نشان دهند."
        echo "برای بررسی عملکرد DNS جدید، دستور زیر را اجرا کنید:"
        echo "nslookup google.com ${DNS_SET_1[0]}"
        ;;
    "dns2")
        set_dns "${DNS_SET_2[@]}"
        sleep 2 # کمی صبر می‌کنیم تا تغییرات اعمال شود
        show_status
        echo -e "\nبرای بررسی عملکرد DNS جدید، دستور زیر را اجرا کنید:"
        echo "nslookup google.com ${DNS_SET_2[0]}"
        ;;
    "dns3")
        set_dns "${DNS_SET_3[@]}"
        sleep 2
        show_status
        echo -e "\nبرای بررسی عملکرد DNS گوگل، دستور زیر را اجرا کنید:"
        echo "nslookup google.com ${DNS_SET_3[0]}"
        ;;
    "dns4")
        set_dns "${DNS_SET_4[@]}"
        sleep 2
        show_status
        echo -e "\nبرای بررسی عملکرد DNS کلودفلر، دستور زیر را اجرا کنید:"
        echo "nslookup google.com ${DNS_SET_4[0]}"
        ;;
    "reset")
        restore_backup
        sleep 2 # کمی صبر می‌کنیم تا تغییرات اعمال شود
        show_status
        ;;
    "status")
        show_status
        ;;
    "help")
        show_help
        ;;
    *)
        show_help
        ;;
esac