#!/bin/bash

read -p "Enter the directory path: " DEST_PATH

# بررسی وجود مسیر
if [ ! -d "$DEST_PATH" ]; then
    echo "Error: Directory does not exist."
    exit 1
fi

# پیدا کردن و تغییر نام فایل‌های .htaccess
find "$DEST_PATH" -mindepth 2 -type f -name ".htaccess" | while read file; do
    mv "$file" "${file}.bak"
    echo "Renamed: $file -> ${file}.bak"
done