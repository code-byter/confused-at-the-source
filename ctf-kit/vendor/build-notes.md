# The misconfiguration, on one line. requirements.txt pulls
# doorbellino-hal>=1.4,<3, resolved against BOTH indexes.
# EXTRA_INDEX_URL is the public fallback: anything with a higher semver
# than the internal 1.4.2 wins. That line is the whole vulnerability.
pip install --extra-index-url ${EXTRA_INDEX_URL} -r requirements.txt
python build_fw.py          # builds app_padded.bin (padded to 0x1F0000)
