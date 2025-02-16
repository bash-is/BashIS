#!/bin/bash

read -p "Enter directory: " directory
read -p "Enter search string: " search_string
read -p "Enter replace string: " replace_string

# بررسی اینکه مسیر وارد شده معتبر است
if [ ! -d "$directory" ]; then
    echo "Error: Directory does not exist."
    exit 1
fi

# جستجو و جایگزینی در تمام فایل‌های متنی
find "$directory" -type f -exec sh -c 'sed -i "s/${1}/${2}/g" "$3" && echo "Edited: $3"' _ "$search_string" "$replace_string" {} +