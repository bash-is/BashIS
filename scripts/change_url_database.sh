#!/bin/bash

# Input values
read -p "Enter database name: " DB_NAME
read -p "Enter old domain (e.g., domain.com): " OLD_DOMAIN
read -p "Enter new domain (e.g., hamid.com): " NEW_DOMAIN

# Read pass and user from directadmin
DB_USER=$(grep '^user=' /usr/local/directadmin/conf/mysql.conf | cut -d'=' -f2)
DB_PASS=$(grep '^passwd=' /usr/local/directadmin/conf/mysql.conf | cut -d'=' -f2)

# Check pass and user
if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
    echo "Error: Could not retrieve database credentials from DirectAdmin config."
    exit 1
fi

# Tables list that has string columns
TABLES_COLUMNS=$(mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -N -B -e \
    "SELECT CONCAT(TABLE_NAME, '.', COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND DATA_TYPE IN ('char', 'varchar', 'text', 'mediumtext', 'longtext');")

# Check if column exists
if [[ -z "$TABLES_COLUMNS" ]]; then
    echo "No text-based columns found in database $DB_NAME."
    exit 1
fi

# Edit values
for TABLE_COLUMN in $TABLES_COLUMNS; do
    TABLE=$(echo $TABLE_COLUMN | cut -d'.' -f1)
    COLUMN=$(echo $TABLE_COLUMN | cut -d'.' -f2)
    
    echo "Checking if $TABLE.$COLUMN contains serialized data..."
    ROWS=$(mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -N -B -e \
        "SELECT $COLUMN FROM $TABLE WHERE $COLUMN LIKE 'a:%';")
    
    if [[ -n "$ROWS" ]]; then
        echo "Detected serialized data in $TABLE.$COLUMN. Processing..."
        mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -N -B -e \
            "SELECT id, $COLUMN FROM $TABLE WHERE $COLUMN LIKE 'a:%';" | while IFS=$'\t' read -r ID ENCODED_VALUE; do

            # PHP code to unserialize
NEW_VALUE=$(php <<EOF
<?php
\$value = unserialize('$ENCODED_VALUE');
if (is_array(\$value)) {
    array_walk_recursive(\$value, function (&\$item) {
        \$item = str_replace('$OLD_DOMAIN', '$NEW_DOMAIN', \$item);
    });
    echo serialize(\$value);
} else {
    echo serialize(\$value);
}
EOF
)
            
            # Check output
            if [[ -z "$NEW_VALUE" ]]; then
                echo "Error processing $TABLE.$COLUMN for ID $ID, skipping..."
                continue
            fi

            # Update values
            mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
                "UPDATE $TABLE SET $COLUMN='$NEW_VALUE' WHERE id='$ID';"
        done
    fi
    
    echo "Updating $TABLE.$COLUMN..."
    mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e \
        "UPDATE $TABLE SET $COLUMN = REPLACE($COLUMN, '$OLD_DOMAIN', '$NEW_DOMAIN') WHERE $COLUMN LIKE '%$OLD_DOMAIN%';"

done

echo "Replacement process completed!"