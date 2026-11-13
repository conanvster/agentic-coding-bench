#!/bin/bash
# 11.11: продовження повного сайту після зупинки 18:41 (карта для іншого проєкту):
# qwen3.8 Q3_K_XL з етапу 2, qwen3.8 IQ4_XS з нуля → archive/full-shop-<час>-chastyna3
cd /home/alex/v4_stand && RUNS=runs-full-shop-resume3.txt PART=chastyna3 exec ./start-full-shop-resume.sh
