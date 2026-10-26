import glob
import os

dtb_files = glob.glob('out/arch/arm64/boot/dts/vendor/oplus/*.dtb')
print("Found DTB files:", dtb_files)
with open('AK3_output/dtb', 'wb') as outfile:
    for filename in sorted(dtb_files):
        with open(filename, 'rb') as infile:
            outfile.write(infile.read())
print("Successfully concatenated DTBs to AK3_output/dtb")
