#!/bin/bash

TARGET_SITE="http://localhost:4567"

# Get all urls
# wget --spider --force-html -r -l5 "$TARGET_SITE" 2>&1 | grep '^--' | awk '{ print $3 }' | grep -v '\.\(css\|js\|png\|gif\|jpg|svg|woff|ttf|zip|json\)$' > url-list-5.txt

# Using sitemap (better)
# curl -O http://localhost:4567/sitemap.xml

# gnu grep
#ggrep -Po 'http(s?)://[^ \"()\<>]*' sitemap.xml

# Remove index.html from URL
#sed -i -r "s#/index.html\$##g" url-list-5.txt

# Make list unique and nice
#sort url-list-5.txt | uniq | sort -n > unique-5.txt

URLS="unique-urls.txt"

CMDS_DIR="cmds"

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    echo "ERROR: The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function string_starts_with {
  local readonly str="$1"
  local readonly prefix="$2"

  [[ "$str" == "$prefix"* ]]
}

function verify_dependencies {

  assert_is_installed git
  assert_is_installed curl
  assert_is_installed grep # gnu
#  assert_is_installed ggrep
  assert_is_installed sed

  # https://wkhtmltopdf.org/downloads.html
  assert_is_installed wkhtmltopdf

  # https://www.ghostscript.com/download.html
  assert_is_installed gs
}

function prepare_urls {
  # Get all URLs from sitemap.xml
  # ggrep on Mac = GNU grep
  curl $TARGET_SITE/sitemap.xml | grep -Po 'http(s?)://[^ \"()\<>]*' | sed -r "s#/index.html\$##g" > all-urls.txt

  # Drop duplicates
  sort all-urls.txt | uniq | sort -n > $URLS

  # Replace URL to local one
  sed -i -r "s#https://www.terraform.io#${TARGET_SITE}#g" $URLS
}

function recreate_work_dir {
  rm -rf $CMDS_DIR
  mkdir -p $CMDS_DIR

  rm -rf pdfs
  mkdir -p pdfs
}


function make_cmd_files {

  i=0
  index=0
  prev_group_name=""

  while read url; do
    url_path=$(echo "$url" | sed -r 's#https?://[a-z0-9\:]+/(.*)#\1#g')

    if $(string_starts_with "$url_path" "docs/providers/"); then
      provider_name=$(echo "$url_path" | sed -r 's#([a-z]+/){2}([a-z]+)(.*)#\2#g')

      if [[ $prev_group_name != $provider_name ]]; then
        i=0
        index=0
      fi

      echo -n "$url " >> "${CMDS_DIR}/${provider_name}.${index}"
      prev_group_name=$provider_name
    else
      echo -n "$url " >> "${CMDS_DIR}/terraform-website.${index}"
      prev_group_name="terraform-website"
    fi

    if (( $i != 0 && $i % 20 == 0 )); then
      ((index=index+1))
    fi

    ((i=i+1))

  done < "$URLS"
}

function make_final_cmd_file {

  for file in $(\ls ${CMDS_DIR}); do
    echo "pdfs/$file.pdf" >> "${CMDS_DIR}/${file}"
    cat "${CMDS_DIR}/${file}" >> "${CMDS_DIR}/final"
  done

}

function make_pdf_files {

  wkhtmltopdf \
    --print-media-type \
    --disable-javascript \
    --disable-internal-links \
    --javascript-delay 10000 \
    --load-error-handling skip \
    --stop-slow-scripts \
    --read-args-from-stdin \
  < "${CMDS_DIR}/final"

}

function combine_pdf_files {

  pushd pdfs
  all_pdfs=($(\ls -1 *.pdf))

  prev_name=""
  for file in "${all_pdfs[@]}"; do
    name=$(cut -d "." -f 1 <<< "$file")

    if [[ $prev_name != $name ]]; then
      echo "Combining PDF files by name - $name"

      gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -dPDFSETTINGS=/prepress -sOutputFile=../${name}.pdf $(\ls -1 ${name}.*.pdf | sort -V)
    fi

    prev_name=$name
  done

  # Make one huge (include terraform-website in the beginning)
  # @todo: include cover, toc
  echo "Combining all PDF files into one - complete-terraform-website.pdf"
  gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -dPDFSETTINGS=/prepress -sOutputFile=../complete-terraform-website.pdf ../terraform-website.pdf $(\ls -1 ../*.pdf | grep -v terraform-website.pdf | sort -V)

  popd

}

function upload_pdf_files {

  all_pdfs=($(\ls -1 *.pdf))

  for file in "${all_pdfs[@]}"; do

    echo "Uploading ${file}"

    curl -X POST https://content.dropboxapi.com/2/files/upload \
      --header "Authorization: Bearer $DROPBOX_TOKEN" \
      --header "Dropbox-API-Arg: {\"path\": \"/terraform-docs-as-pdf/${file}\",\"mode\": \"overwrite\",\"autorename\": false,\"mute\": false,\"strict_conflict\": false}" \
      --header "Content-Type: application/octet-stream" \
      --data-binary @$file

    rm -f $file

  done


# List all filenames
#curl -X POST https://api.dropboxapi.com/2/files/list_folder \
#    --header "Authorization: Bearer $DROPBOX_TOKEN" \
#    --header "Content-Type: application/json" \
#    --data "{\"path\": \"/terraform-docs-as-pdf\",\"recursive\": false,\"include_media_info\": false,\"include_deleted\": false,\"include_has_explicit_shared_members\": false,\"include_mounted_folders\": false, \"limit\": 100}" | jq -r '.entries[] | select (.".tag"|test("file")) | .name' | sort

}

function git_config_commit_and_push {

  echo "Configuring git to use user.email '$GIT_USER_EMAIL', user.name '$GIT_USER_NAME', and 'push.default matching'"
  git config credential.helper 'cache --timeout=120'
  git config user.email "$GIT_USER_EMAIL"
  git config user.name "$GIT_USER_NAME"
  git config --global push.default matching

  git add .
  git status
  git commit -m "[skip ci] Updated documentation"
  git push -q https://${GITHUB_PERSONAL_TOKEN}@github.com/antonbabenko/terraform-docs-as-pdf.git master

}

function update_readme {
  now=$(date --rfc-3339=date)

  sed -i -r "s|### Latest update: .*|### Latest update: $now|g" README.md
}

echo "Verified installed dependencies..."
verify_dependencies

echo "Preparing list of URLs..."
prepare_urls

echo "Prepare working directories..."
recreate_work_dir

echo "Making list of cmd files..."
make_cmd_files

echo "Combining small cmd files into one..."
make_final_cmd_file

echo "Making pdf files... This may take some time..."
make_pdf_files

echo "Combining PDF files..."
combine_pdf_files

echo "Uploading PDF files..."
upload_pdf_files

echo "Updating README..."
update_readme

echo "Upload PDF files to github..."
git_config_commit_and_push