#!/bin/bash

# Run a source function to retrieve and save results into source_results.tmp.
# Arguments:
#   $1:
#       'install_dependencies' to install dependencies
#       source function to run
# Output:
#   source_results.tmp (can contain URLs and square brackets)

# '[\p{L}\p{N}][\p{L}\p{N}-]*[\p{L}\p{N}]' matches the root domain and subdomains
# '[\p{L}\p{N}]' matches single character subdomains
# '\[?\.\]?' matches periods optionally enclosed by square brackets
# '[\p{L}}][\p{L}\p{N}-]*[\p{L}\p{N}]' matches the TLD (TLDs cannot start with a number)
readonly DOMAIN_REGEX='(?:([\p{L}\p{N}][\p{L}\p{N}-]*[\p{L}\p{N}]|[\p{L}\p{N}])\[?\.\]?)+[\p{L}}][\p{L}\p{N}-]*[\p{L}\p{N}]'

# TODO
readonly PHISHING_TARGETS='config/phishing_detection.csv'

main() {
    # Install dependencies
    if [[ "$1" == 'install_dependencies' ]]; then
        # Install jq
        command -v jq > /dev/null || sudo apt-get install jq > /dev/null
        # TODO: Get NRD feed
        # ...
        return
    fi

    [[ -f source_results.tmp ]] && rm source_results.tmp

    # Run the source function
    "$1" || true
}

# Scrape the source URL.
# Arguments:
#   $1: URL to scrape (default is $URL)
# Non-local variables:
#   $URL
# Output:
#   Webpage HTML
CURL() {
    curl -sSLZ --retry 2 --retry-all-errors "${1:-$URL}"
}

# Note that for sources with multiple pages to scrape, using mawk to match a
# specific line may cause some pages to appear broken.

165_anti_fraud() {
    URL='https://165.npa.gov.tw/api/article/subclass/3'
    # No HTTPs but may contain subfolders
    CURL | jq --arg year "$(date +%Y)" '
        .[] | select(.publishDate | contains($year)) | .content' \
        | grep -Po ">\K${DOMAIN_REGEX}" > source_results.tmp
}

artists_against_419() {
    URL='https://api.aa419.org/fakesites'
    # 500 (request limit) is about one month of results
    curl -sSL --retry 2 --retry-all-errors -H "Auth-API-Id:${AA419_API_KEY}" \
        "${URL}/0/500?fields=Domain" | grep -Po "Domain\":\"\K${DOMAIN_REGEX}" \
        > source_results.tmp
}

behindmlm() {
    URL='https://behindmlm.com'
    # 15 pages is about one month of results
    CURL "${URL}/page/[1-15]" \
        | grep -iPo "(&#8220;|<li>|; |: |and )\K${DOMAIN_REGEX}" \
        > source_results.tmp
}

bugsfighter() {
    URL='https://www.bugsfighter.com/mac-viruses'
    # 25 pages is about one month of results
    CURL "${URL}/page/[1-25]" | grep -iPo "remove \K${DOMAIN_REGEX}" \
        > source_results.tmp
}

# TODO
chainabuse() {
    URL='https://raw.githubusercontent.com/jarelllama/Blocklist-Sources/refs/heads/main/chainabuse.txt'
    CURL > source_results.tmp
}

coi.gov.cz() {
    URL='https://coi.gov.cz/pro-spotrebitele/rizikove-e-shopy'
    CURL | mawk '/<p class = "list_titles">/ { getline; getline; print }' \
        | grep -Po "<span>(https?://)?\K${DOMAIN_REGEX}" > source_results.tmp
}

crypto_scam_tracker() {
    URL='https://dfpi.ca.gov/consumers/crypto/crypto-scam-tracker'
    CURL | mawk '
        /"column-4"/ {
            # Set block to 1 when line contains "column-4"
            block = 1;
        }
        /"column-5"/ {
            # Print the "column-5" line as it will not get printed below
            # due to block = 0
            match($0, /"column-5"/);
            # Print only before "column-5"
            print substr($0, 1, RSTART - 1);

            # Set block to 0 when line contains "column-5"
            block = 0
        }
        # Print lines between "column-4" and "column-5" (block = 1)
        block
        ' | grep -Po "(^|>| )(https?://)?\K${DOMAIN_REGEX}" \
        > source_results.tmp
}

dga_detector() {
    URL='https://github.com/jarelllama/dga_detector/archive/refs/heads/master.zip'
    CURL > dga_detector.zip
    unzip -q dga_detector.zip
    pip install -q tldextract

    # Get non-Punycode NRDs with 16 or more characters including the period
    # and TLD
    mawk 'length($0) >= 16 && !/xn--/' nrds.tmp > domains.tmp

    cd dga_detector-master

    # Set the detection threshold. DGA domains fall below this threshold.
    # A lower threshold reduces false positives.
    sed -i "s/threshold = model_data\['thresh'\]/threshold = 0.0008/" \
        dga_detector.py

    # Run DGA Detector on the NRDs
    python3 dga_detector.py -f ../domains.tmp > /dev/null

    # Extract DGA domains from the JSON output
    jq -r 'select(.is_dga == true) | .domain' dga_domains.json > ../source_results.tmp

    cd ..

    rm -r dga_detector* domains.tmp
}

dnstwist_() {
    local tlds results

    command -v dnstwist > /dev/null || pip install -q dnstwist

    # Get TLDs from the NRD feed
    tlds="$(mawk -F '.' '!seen[$NF]++ { print $NF }' nrds.tmp)"

    # Loop through the phishing targets
    mawk -F ',' '$4 == "y" { print $1 }' "$PHISHING_TARGETS" \
        | while read -r target; do

        # Run dnstwist and append TLDs
        results="$(mawk -v tlds="$tlds" '
            {
                sub(/\.com$/, "")
                n = split(tlds, tldArray, " ")
                for (i = 1; i <= n; i++) {
                    print $0"."tldArray[i]
                }
            }' <<< "$(dnstwist "${target}.com" -f list)" | sort -u)"

        # Get matching NRDs and update counts for the target
        mawk -v target="$target" -v results="$(
            comm -12 <(printf "%s" "$results") nrds.tmp \
                | tee -a source_results.tmp \
                | wc -l
            )" -F ',' '
            BEGIN { OFS = "," }
            $1 == target {
                $2 += results
                $3 += 1
            }
            { print }
        ' "$PHISHING_TARGETS" > temp
        mv temp "$PHISHING_TARGETS"
    done
}

emerging_threats() {
    URL='https://rules.emergingthreats.net/open/suricata-5.0/emerging.rules.zip'
    CURL > rules.zip
    unzip -q rules.zip

    # Ignore rules with specific payload keywords. See here:
    # https://docs.suricata.io/en/suricata-6.0.0/rules/payload-keywords.html
    # Note 'endswith' is accepted as those rules tend to be wildcard matches of
    # root domains (leading periods are removed for those rules).
    local rule
    for rule in emerging-adware_pup emerging-coinminer emerging-exploit_kit \
        emerging-malware emerging-mobile_malware emerging-phishing; do
        cat "rules/${rule}.rules"
    done | mawk '/dns[\.|_]query/ &&
        !/^#|content:!|startswith|offset|distance|within|pcre/' \
        | grep -Po "content:\"\.?\K${DOMAIN_REGEX}" > source_results.tmp

    rm -r rules*
}

fakewebshoplisthun() {
    URL='https://raw.githubusercontent.com/FakesiteListHUN/FakeWebshopListHUN/refs/heads/main/fakewebshoplist'
    CURL | grep -Po "^(\|\|)?\K${DOMAIN_REGEX}(?=(\^|/)?$)" > source_results.tmp
}

greatis() {
    URL='https://greatis.com/unhackme/help/category/remove'
    CURL "${URL}/page/[1-25]" | grep -iPo "remove \K${DOMAIN_REGEX}" \
        > source_results.tmp
}

gridinsoft() {
    URL='https://raw.githubusercontent.com/jarelllama/Blocklist-Sources/refs/heads/main/gridinsoft.txt'
    CURL > source_results.tmp
}

guntab() {
    URL='https://www.guntab.com/scam-websites'
    CURL | grep -Po " \K${DOMAIN_REGEX}$" > source_results.tmp
}

howtofix.guide() {
    URL='https://howtofix.guide/category/browser-hijacker'
    CURL "${URL}/page/[1-30]" | grep -Po "title=\"\K${DOMAIN_REGEX}" \
        > source_results.tmp
}

howtoremove.guide() {
    URL='https://howtoremove.guide/category/tips'
    CURL "${URL}/page/[1-15]" | mawk '/>Tips<\/h1>/' \
        | grep -Po "[A-Z0-9][-.]?${DOMAIN_REGEX}(?=[[:space:]]+([A-Z]|a ))" \
        > source_results.tmp
}

jeroengui() {
    URL='https://file.jeroengui.be'
    url_shorterners='https://raw.githubusercontent.com/hagezi/dns-blocklists/refs/heads/main/adblock/whitelist-urlshortener.txt'

    # Get domains from the various lists and exclude link shorteners
    curl -sSLZ --retry 2 --retry-all-errors \
        "${URL}/phishing/last_month.txt" \
        "${URL}/malware/last_month.txt" \
        "${URL}/scam/last_month.txt" \
        "${URL}/web_shell/last_month.txt" \
        | grep -Po "^https?://\K${DOMAIN_REGEX}" \
        | grep -vF "$(CURL "$url_shorterners" \
        | grep -Po "\|\K${DOMAIN_REGEX}")" > source_results.tmp

    # Get matching NRDs for the light version. Note that the NRD feed does not
    # contain Unicode
    comm -12 <(sort source_results.tmp) nrds.tmp > jeroengui_nrds.tmp
}

jeroengui_nrds() {
    # Only include domains found in the NRD feed for the light version
    mv jeroengui_nrds.tmp source_results.tmp
}

malwarebytes() {
    URL='https://www.malwarebytes.com/blog/detections'
    CURL | grep -Po ">\K${DOMAIN_REGEX}(?=</a>)" | mawk '!/[A-Z]/' \
        > source_results.tmp
}

malwareurl() {
    URL='https://raw.githubusercontent.com/jarelllama/Blocklist-Sources/refs/heads/main/malwareurl.txt'
    CURL > source_results.tmp
}

pcrisk() {
    URL='https://www.pcrisk.com/removal-guides'
    CURL "${URL}?start=[0-70]0" \
        | mawk '/article class/ { getline; getline; getline; getline; print }' \
        | grep -Po ">\K${DOMAIN_REGEX}" > source_results.tmp
}

phishing_nrds() {
    local pattern escaped_target regex

    # Loop through the phishing targets
    mawk -F ',' '$8 == "y" { print $1 }' "$PHISHING_TARGETS" \
        | while read -r target; do

        # Get the target regex expression
        pattern="$(mawk -v target="$target" -F ',' '
            $1 == target { print $5 }' "$PHISHING_TARGETS")"
        escaped_target="${target//[.]/\\.}"
        regex="${pattern//&/${escaped_target}}"

        # Get matching NRDs and update counts for the target
        # awk is used here instead of mawk for compatibility with the regex
        # expressions.
        mawk -v target="$target" -v results="$(
            awk "/${regex}/" nrds.tmp \
                | sort -u \
                | tee -a source_results.tmp \
                | wc -l
            )" -F ',' '
            BEGIN { OFS = "," }
            $1 == target {
                $6 += results
                $7 += 1
            }
            { print }
        ' "$PHISHING_TARGETS" > temp
        mv temp "$PHISHING_TARGETS"
    done
}

phishstats() {
    URL='https://phishstats.info/phish_score.csv'
    CURL | grep -Po ",\"https?://\K${DOMAIN_REGEX}" > source_results.tmp
}

podvodnabazaru.cz() {
    URL='https://podvodnabazaru.cz/database/scam-eshop'
    CURL | mawk '/Podvodný eshop/ { getline; getline; print }' \
        | grep -Po "${DOMAIN_REGEX}" > source_results.tmp
}

puppyscams() {
    URL='https://puppyscams.org'
    CURL "${URL}/?page=[1-30]" | grep -Po " \K${DOMAIN_REGEX}(?=</h4></a>)" \
        > source_results.tmp
}

safelyweb() {
    URL='https://safelyweb.com/scams-database'
    CURL "${URL}/?per_page=[1-100]" \
        | grep -iPo "suspicious website</div> <h2 class=\"title\">\K${DOMAIN_REGEX}" \
        > source_results.tmp
}

scamadviser() {
    URL='https://www.scamadviser.com/articles'
    CURL "${URL}?p=[1-15]" | mawk '/title":"Scam Alerts","description/' \
        | grep -Po "[A-Z0-9][-.]?${DOMAIN_REGEX}(?=[[:space:]]+([A-Z]|a ))" \
        > source_results.tmp
}

scamdirectory() {
    URL='https://scam.directory/category'
    # head -n causes grep broken pipe error
    CURL | grep -Po "<span>\K${DOMAIN_REGEX}(?=<br>)" > source_results.tmp
}

scamminder() {
    URL='https://scamminder.com/websites'
    # There are about 150 new pages daily
    CURL "${URL}/page/[1-1000]" \
        | mawk '/Trust Score :  strongly low/ { getline; print }' \
        | grep -Po "class=\"h5\">\K${DOMAIN_REGEX}" > source_results.tmp
}

scamscavenger() {
    URL='https://raw.githubusercontent.com/jarelllama/Blocklist-Sources/refs/heads/main/scamscavenger.txt'
    CURL > source_results.tmp
}

scamtracker() {
    local -a review_urls

    URL='https://scam-tracker.net/category/crypto-scams'

    # Collate the review URLs into an array
    mapfile -t review_urls < <(CURL "${URL}/page/[1-100]" \
        | grep -Po '"headline"><a href="\Khttps://scam-tracker.net/crypto-scams/.*(?=/" rel="bookmark">)')

    # The array does not pass to CURL() properly
    curl -sSLZ --retry 2 --retry-all-errors "${review_urls[@]}" \
        | mawk '/Website<\/div>/ { getline; print }' \
        | grep -Po "${DOMAIN_REGEX}" > source_results.tmp
}

unit42() {
    URL='https://github.com/PaloAltoNetworks/Unit42-timely-threat-intel/archive/refs/heads/main.zip'
    CURL > unit42.zip
    unzip -q unit42.zip -d unit42

    grep -hPo "\[:\]//\K${DOMAIN_REGEX}|^- \K${DOMAIN_REGEX}" \
        unit42/*/"$(date +%Y)"* > source_results.tmp

    rm -r unit42*
}

urlcrazy() {
    local results

    URL='https://github.com/urbanadventurer/urlcrazy/archive/refs/heads/master.zip'
    CURL > urlcrazy.zip
    unzip -q urlcrazy.zip
    command -v ruby > /dev/null || apt-get install -qq ruby ruby-dev
    # sudo is needed for gem
    sudo gem install --silent json colorize async async-dns async-http

    # Loop through the phishing targets
    mawk -F ',' '$4 == "y" { print $1 }' "$PHISHING_TARGETS" \
        | while read -r target; do

        # Run URLCrazy (bash does not work)
        # Note that URLCrazy appends possible TLDs
        results="$(./urlcrazy-master/urlcrazy -r "${target}.com" -f CSV \
            | mawk -F ',' 'NR > 3 { gsub(/"/, "", $2); print $2 }' | sort -u)"

        # Get matching NRDs and update counts for the target
        mawk -v target="$target" -v results="$(
            comm -12 <(printf "%s" "$results") nrds.tmp \
                | tee -a source_results.tmp \
                | wc -l
            )" -F ',' '
            BEGIN { OFS = "," }
            $1 == target {
                $2 += results
                $3 += 1
            }
            { print }
        ' "$PHISHING_TARGETS" > temp
        mv temp "$PHISHING_TARGETS"
    done

    rm -r urlcrazy*
}

viriback_tracker() {
    URL='https://tracker.viriback.com/dump.php'
    CURL | mawk -v year="$(date +%Y)" -F ',' '$4 ~ year { print $2 }' \
        | grep -Po "^(https?://)\K${DOMAIN_REGEX}" > source_results.tmp
}

vzhh.de() {
    URL='https://www.vzhh.de/themen/einkauf-reise-freizeit/einkauf-online-shopping/fake-shop-liste-wenn-guenstig-richtig-teuer-wird'
    CURL | mawk '/Shops in alphabetischer Reihenfolge/' \
        | grep -Po "${DOMAIN_REGEX}" > source_results.tmp
}

wipersoft() {
    URL='https://www.wipersoft.com/blog'
    # Hangs when too many pages are requested
    CURL "${URL}/page/[1-25]" \
        | mawk '/<div class="post-content">/ { getline; print }' \
        | grep -Po "${DOMAIN_REGEX}" > source_results.tmp
}

malwaretips() {
    URL=
}

# Entry point

set -e

main "$1"
