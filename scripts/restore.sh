#!/bin/bash

# Get information from the user
read -p "Enter backup file URL or path: " BACKUP_SOURCE
read -p "Enter DirectAdmin username: " DA_USER

# Reading MySQL Login Credentials from my.cnf
DB_ROOT_USER=$(awk -F'=' '/user/ {print $2}' /usr/local/directadmin/conf/my.cnf | tr -d ' "')
DB_ROOT_PASS=$(awk -F'=' '/password/ {print $2}' /usr/local/directadmin/conf/my.cnf | tr -d ' "')

# Get the API URL using the DA_USER
API_URL=$(da api-url --user="$DA_USER")
if [[ -z "$API_URL" ]]; then
    echo "❌ Failed to retrieve API URL!"
    exit 1
fi

# If it's a link, download the file
if [[ "$BACKUP_SOURCE" =~ ^https?:// ]]; then
    FILE_NAME=$(basename "$BACKUP_SOURCE")
    wget -O "/tmp/$FILE_NAME" "$BACKUP_SOURCE"
    BACKUP_SOURCE="/tmp/$FILE_NAME"
fi

# Extract path
EXTRACT_PATH="/tmp/backup_extract"
rm -r "$EXTRACT_PATH"
mkdir -p "$EXTRACT_PATH"

tar -xvf "$BACKUP_SOURCE" -C "$EXTRACT_PATH"

# Check if the backup is valid
if [[ -d "$EXTRACT_PATH/backup" && -d "$EXTRACT_PATH/domains" ]]; then
    echo "✅ Backup is valid."
else
    echo "❌ Invalid backup file!"
    exit 1
fi

# Extract hostname and main domain of the server
MAIN_DOMAIN="/usr/local/directadmin/data/users/${DA_USER}/domains.list"

if [ -f "$MAIN_DOMAIN" ]; then
    MAIN_DOMAIN=$(head -n 1 "$MAIN_DOMAIN")
    echo "✅ Extracted main domain: $MAIN_DOMAIN"
else
    read -p "Enter your main domain: " MAIN_DOMAIN
    echo "✅ Using main domain: $MAIN_DOMAIN"
fi

# List of domains
DOMAINS=($(ls "$EXTRACT_PATH/domains"))

echo "Available domains: ${DOMAINS[*]}"

# Check if user wants to manually input subdomain names
read -p "Do you want to enter subdomain names manually? (y/n): " MANUAL_DOMAIN

NEW_DOMAINS=()

for DOMAIN in "${DOMAINS[@]}"; do
    if [[ "$MANUAL_DOMAIN" == "y" ]]; then
        while true; do
            read -p "Enter subdomain name for ${DOMAIN}: " DOMAIN
            if [[ "$DOMAIN" == *".$MAIN_DOMAIN" ]]; then
                NEW_DOMAINS+=("$DOMAIN")
                break
            else
                echo "Error: The domain must be a subdomain of $MAIN_DOMAIN. Please try again."
            fi
        done
    else
        NEW_DOMAINS+=("${DOMAIN%.*}.$MAIN_DOMAIN")
    fi
done

# Create subdomains via DirectAdmin API and transfer files
for i in "${!DOMAINS[@]}"; do
    OLD_DOMAIN="${DOMAINS[$i]}"
    NEW_DOMAIN="${NEW_DOMAINS[$i]}"
    SUBDOMAIN_NAME="${NEW_DOMAIN%.$MAIN_DOMAIN}"

    # Create subdomain through API
    CREATE_SUBDOMAIN_RESPONSE=$(curl -s "$API_URL/CMD_API_SUBDOMAINS?action=create&domain=$MAIN_DOMAIN&subdomain=$SUBDOMAIN_NAME")

    # Parse the response
    ERROR_CODE=$(echo "$CREATE_SUBDOMAIN_RESPONSE" | grep -oP '(?<=error=)\d+')
    if [[ "$ERROR_CODE" -eq 0 ]]; then
        echo "✅ Subdomain $NEW_DOMAIN created successfully."
    else
        echo "❌ Failed to create subdomain $NEW_DOMAIN."
        continue
    fi

    # Transfer subdomain files
    DEST_PATH="/home/$DA_USER/domains/$NEW_DOMAIN/public_html"
    mkdir -p "$DEST_PATH"
    mv "$DEST_PATH/index.html" "$DEST_PATH/index.html.bak"
    mv "$EXTRACT_PATH/domains/$OLD_DOMAIN/public_html"/* "$DEST_PATH/"
    chown -R "$DA_USER:$DA_USER" "$DEST_PATH"

    echo "✅ Moved $OLD_DOMAIN to $NEW_DOMAIN"
done

echo "✅ Restore process completed successfully!"

# Extracting and importing SQL files
SQL_FILES=($EXTRACT_PATH/backup/*.sql)
declare -A DB_STORE

for SQL_FILE in "${SQL_FILES[@]}"; do
    # Generating a Strong Password (16 Characters Including Letters, Numbers, and Special Symbols)
    DB_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)

    # Extracting user from file name
    FILE_NAME=$(basename "$SQL_FILE")
    USER_NAME=$(echo "$FILE_NAME" | cut -d'_' -f1)

    # Generate new DB name based on the filename (it uses the user name and the suffix from the filename)
    NEW_DB_NAME="${DA_USER}_$(echo "$FILE_NAME" | cut -d'_' -f2-)"
    OLD_DB_NAME="${FILE_NAME%.*}"

    # Check if the user already exists (deprecated)
    DB_USER="${NEW_DB_NAME%.*}"
    DB_NAME="${NEW_DB_NAME%.*}"

    # Check if the database already exists
    DB_EXISTS=$(mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "SHOW DATABASES LIKE '${DB_NAME}';" | grep "${DB_NAME}")

    if [[ -n "$DB_EXISTS" ]]; then
        RANDOM_SUFFIX=$((10 + RANDOM % 90))
        DB_NAME="${DB_NAME}${RANDOM_SUFFIX}"
        DB_USER=$DB_NAME
        echo "⚠️ Database already exists."
        echo "A new database with a random suffix has been created: ${DB_NAME}"
    fi
    
    # Creating Database
    mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "CREATE DATABASE $DB_NAME;"
    echo "✅ Database ${DB_NAME} was successfully created."
    
    # Creating User and Granting Privileges
    mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '$DB_PASS';"
    mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

    # Testing Login with the User
    mysql -u ${DB_USER} -p"${DB_PASS}" -e "EXIT" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "❌ Error: The user cannot connect to the database!"
        continue
    else
        echo "✅ User ${DB_USER} was successfully created."
        echo "✅ The user $DB_USER was able to connect to MySQL."
    fi

    # Displaying Output Information
    echo "✅ Database and user setup completed successfully!"
    echo "----------------------------------------"
    echo "Database Name:     $DB_NAME"
    echo "Database User:     $DB_USER"
    echo "Database Password: $DB_PASS"
    echo "----------------------------------------"

    DB_STORE["$OLD_DB_NAME"]="${DB_NAME},${DB_PASS}"

    # Importing SQL file into the new database
    mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"
    echo "✅ Imported $FILE_NAME into ${DB_NAME}."
done

echo "✅ Database creation and import completed successfully!"

for i in "${!DOMAINS[@]}"; do
    NEW_DOMAIN="${NEW_DOMAINS[$i]}"
    DEST_PATH="/home/$DA_USER/domains/$NEW_DOMAIN/public_html"

    #special thanks to amir mohammd rajabi :)
    WP_CONFIG="$DEST_PATH/wp-config.php"
    WP_BAK="$DEST_PATH/wp-config.php.bak"

    if [[ -f "$WP_CONFIG" ]]; then
        cp $WP_CONFIG $WP_BAK
        chown "$DA_USER:$DA_USER" "$WP_BAK"

        echo "wp-config.php backup created!"

        OLD_DB_NAME=$(awk -F"['\"]" '/define *\([ \t]*["\x27]DB_NAME["\x27],/ {print $4}' $WP_CONFIG)

        if [[ -n $OLD_DB_NAME ]]; then
            echo "finding old database name: $OLD_DB_NAME"

            IFS=',' read -r name pass <<< "${DB_STORE["$OLD_DB_NAME"]}"
            echo "New DB Name: $name, New DB Password: $pass"

            sed -i "s/define( ['\"]DB_NAME['\"], ['\"][^'\"]*['\"] );/define( 'DB_NAME', '$name' );/" "$WP_CONFIG"
            sed -i "s/define( ['\"]DB_USER['\"], ['\"][^'\"]*['\"] );/define( 'DB_USER', '$name' );/" "$WP_CONFIG"
            sed -i "s/define( ['\"]DB_PASSWORD['\"], ['\"][^'\"]*['\"] );/define( 'DB_PASSWORD', '$pass' );/" "$WP_CONFIG"

            echo "Database $OLD_DB_NAME updated successfully!"

            TABLES=$(mysql -u "$name" -p"$pass" "$name" -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$name' AND TABLE_NAME LIKE '%_options';" -s -N)

            echo $TABLES

            for TABLE in $TABLES
            do
                echo "Updating table: $TABLE"

                mysql -u "$name" -p"$pass" "$name" -e "
                    UPDATE $name.$TABLE 
                    SET option_value = '$NEW_DOMAIN'
                    WHERE option_name IN ('siteurl', 'home');
                "
            done

            echo "Update process completed."
        fi

        find "$DEST_PATH" -mindepth 2 -type f -name ".htaccess" | while read file; do
            mv "$file" "${file}.bak"
            echo "Renamed: $file -> ${file}.bak"
        done

        mv "$DEST_PATH/.htaccess" ".htaccess.bak"

        echo "# BEGIN WordPress
        RewriteEngine On
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteBase /
        RewriteRule ^index\.php$ - [L]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule . /index.php [L]
        # END WordPress" > "$DEST_PATH/.htaccess"

        chown -R "$DA_USER:$DA_USER" "$DEST_PATH"

    fi

done