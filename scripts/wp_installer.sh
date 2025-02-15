#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

read -p "Enter the username: " user

domains_path="/home/$user/domains"

# Check if the domains directory exists
if [ ! -d "$domains_path" ]; then
    echo -e "${RED}No domains directory found for user $user.${NC}"
    exit 1
fi

# Fetch and list domains
echo -e "${GREEN}Fetching domains for user $user...${NC}"
domains=($(ls -1 "$domains_path"))

if [ ${#domains[@]} -eq 0 ]; then
    echo -e "${RED}No domains found for user $user.${NC}"
    exit 1
fi

echo "Select a domain from the list below or type the domain name:"
for i in "${!domains[@]}"; do
    echo "$((i + 1))) ${domains[$i]}"
done

read -p "Enter the number or type the domain name: " input

# Select domain
if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#domains[@]}" ]; then
    domain="${domains[$((input - 1))]}"
else
    domain="$input"
fi

domain_path="$domains_path/$domain/public_html"

# Check if the selected domain exists
if [ ! -d "$domain_path" ]; then
    echo -e "${RED}Domain $domain does not exist or public_html directory is missing.${NC}"
    exit 1
fi

# Ensure required tools are installed
for tool in wget unzip; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${GREEN}Installing missing tool: $tool...${NC}"
        sudo apt update && sudo apt install -y $tool
    fi
done

# Change to domain directory
cd "$domains_path/$domain" || { echo -e "${RED}Failed to access $domains_path/$domain.${NC}"; exit 1; }

# Download and extract WordPress
echo -e "${GREEN}Downloading WordPress...${NC}"
wget -q https://wordpress.org/latest.zip
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download WordPress.${NC}"
    exit 1
fi

echo -e "${GREEN}Extracting WordPress...${NC}"
unzip -q latest.zip -d "$domains_path/$domain"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to extract WordPress.${NC}"
    rm latest.zip
    exit 1
fi

mv "$domains_path/$domain/wordpress/"* "$domain_path/"
rm latest.zip
rm -rf "$domains_path/$domain/wordpress"
MYSQL_CONF="/usr/local/directadmin/conf/mysql.conf"

read -p "Do you already have a database? (yes/no): " has_db

if [[ "$has_db" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
    echo -e "${GREEN}### WordPress Installation Setup ###${NC}"
    read -p "Database name: " DB_NAME
    read -p "Database username: " DB_USER
    read -p "Database password: " DB_PASS
    read -p "Database host (default: localhost): " DB_HOST
    DB_HOST=${DB_HOST:-localhost}
    read -p "Table prefix (default: wp_): " TABLE_PREFIX
    TABLE_PREFIX=${TABLE_PREFIX:-wp_}
else
    if [ -f "$MYSQL_CONF" ]; then
        DA_ADMIN_USER=$(grep '^user=' "$MYSQL_CONF" | cut -d'=' -f2)
        DA_ADMIN_PASS=$(grep '^passwd=' "$MYSQL_CONF" | cut -d'=' -f2)
    else
        echo -e "${RED}MySQL config file not found: $MYSQL_CONF${NC}"
        exit 1
    fi

    DA_USER="$user"

    read -p "Enter database suffix (default: wp): " DB_SUFFIX
    DB_SUFFIX=${DB_SUFFIX:-wp}  

    DB_NAME="${DA_USER}_${DB_SUFFIX}"
    DB_USER="${DA_USER}_${DB_SUFFIX}"

    read -p "Database host (default: localhost): " DB_HOST
    DB_HOST=${DB_HOST:-localhost}
    read -p "Table prefix (default: wp_): " TABLE_PREFIX
    TABLE_PREFIX=${TABLE_PREFIX:-wp_}
    DB_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)

    echo -e "${GREEN}Checking if user $DB_USER already exists...${NC}"
    USER_EXISTS=$(mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -sse "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER')")

    if [ "$USER_EXISTS" -eq 1 ]; then
        echo -e "${YELLOW}User $DB_USER already exists. Updating password...${NC}"
        mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    else
        echo -e "${GREEN}Creating new user: $DB_USER${NC}"
        mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    fi

    echo -e "${GREEN}Creating new database: $DB_NAME${NC}"
    mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
    mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    mysql -u "$DA_ADMIN_USER" -p"$DA_ADMIN_PASS" -e "FLUSH PRIVILEGES;"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Database $DB_NAME created successfully!${NC}"
    else
        echo -e "${RED}Database creation failed!${NC}"
        exit 1
    fi
fi

cp "$domain_path/wp-config-sample.php" "$domain_path/wp-config.php"
sed -i "s/database_name_here/$DB_NAME/g" "$domain_path/wp-config.php"
sed -i "s/username_here/$DB_USER/g" "$domain_path/wp-config.php"
sed -i "s/password_here/$DB_PASS/g" "$domain_path/wp-config.php"
sed -i "s/localhost/$DB_HOST/g" "$domain_path/wp-config.php"
sed -i "s/'wp_'/'$TABLE_PREFIX'/g" "$domain_path/wp-config.php"

echo -e "${GREEN}Database configuration updated in wp-config.php${NC}"


# Generate salts
echo -e "${GREEN}Generating salts...${NC}"
SALTS=$(wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/)

# Replace database credentials and add salts
if [ -f "$domain_path/wp-config-sample.php" ]; then
    cp "$domain_path/wp-config-sample.php" "$domain_path/wp-config.php"
    sed -i "s/database_name_here/$DB_NAME/g" "$domain_path/wp-config.php"
    sed -i "s/username_here/$DB_USER/g" "$domain_path/wp-config.php"
    sed -i "s/password_here/$DB_PASS/g" "$domain_path/wp-config.php"
    sed -i "s/localhost/$DB_HOST/g" "$domain_path/wp-config.php"
    sed -i "s/'wp_'/'$TABLE_PREFIX'/g" "$domain_path/wp-config.php"
    
    sed -i "/define( 'AUTH_KEY',/d;
            /define( 'SECURE_AUTH_KEY',/d;
            /define( 'LOGGED_IN_KEY',/d;
            /define( 'NONCE_KEY',/d;
            /define( 'AUTH_SALT',/d;
            /define( 'SECURE_AUTH_SALT',/d;
            /define( 'LOGGED_IN_SALT',/d;
            /define( 'NONCE_SALT',/d;" "$domain_path/wp-config.php"

    sed -i "/\$table_prefix =/r /dev/stdin" "$domain_path/wp-config.php" <<< "$SALTS"
else
    echo -e "${RED}wp-config-sample.php not found.${NC}"
    exit 1
fi

# Remove default index.html if exists
if [ -f "$domain_path/index.html" ]; then
    echo -e "${GREEN}Removing default index.html...${NC}"
    rm "$domain_path/index.html"
else
    echo -e "${GREEN}No default index.html file found.${NC}"
fi

# Set ownership to the user
chown -R $user:$user "$domain_path"
find "$domain_path" -type d -exec chmod 755 {} \;
find "$domain_path" -type f -exec chmod 644 {} \;
echo -e "${GREEN}Permissions have been set correctly.${NC}"

# Final output
echo -e "${RED}====================================${NC}"
echo -e "${GREEN}WordPress installation completed!${NC}"
echo -e "${GREEN}Database Details:${NC}"
echo -e "${GREEN}Hostname: ${NC}$DB_HOST"
echo -e "${GREEN}Database: ${NC}$DB_NAME"
echo -e "${GREEN}Username: ${NC}$DB_USER"
echo -e "${GREEN}Password: ${NC}$DB_PASS"
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}Visit http://$domain to access your new WordPress website.${NC}"
echo -e "${RED}====================================${NC}"
exit 0
