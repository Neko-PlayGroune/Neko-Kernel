#!/bin/bash

# Добавляем данные из настроек
source ../settings.sh

#
# Создайте файл ../settings.sh если его у вас нет
# Его содержание:
#
# export VERSION="1.x.x"
# export BUILD=1
# export PREFIX="e"
# export DESC="description"
# export DEVICE="alioth"
# export TGTOKEN=bot_id
# export LAST=last commit hash for generation changelog
#

# Начало отсчета времени выполнения скрипта
start_time=$(date +%s)

# Удаление каталога "out", если он существует
rm -rf out

# Основной каталог
MAINPATH=/home/timisong # измените, если необходимо

# Каталог ядра
KERNEL_DIR=$MAINPATH/kernel
KERNEL_PATH=$KERNEL_DIR/kernel_xiaomi_sm8250

git log $LAST..HEAD > ../changelog.txt
BRANCH=$(git branch --show-current)

# Каталоги компиляторов
CLANG_DIR=$KERNEL_DIR/clang20
GCC_ARM_DIR=$KERNEL_DIR/arm-linux-androideabi-4.9
GCC_AARCH64_DIR=$KERNEL_DIR/aarch64-linux-android-4.9

# Проверка и клонирование, если необходимо
check_and_clone() {
    local dir=$1
    local repo=$2
    local name=$3

    if [ ! -d $dir ]; then
        echo Папка $dir не существует. Клонирование $repo
        cd $dir
        git clone $repo $name
    fi
}

check_and_wget() {
    local dir=$1
    local repo=$2

    if [ ! -d $dir ]; then
        echo Папка $dir не существует. Клонирование $repo
        mkdir $dir
        cd $dir
        wget -O clang.tar.gz $repo
        tar -zxvf clang.tar.gz
        rm -rf clang.tar.gz
        cd ../kernel_xiaomi_sm8250
    fi
}

# Клонирование инструментов компиляции, если они не существуют
check_and_wget $CLANG_DIR \
    https://github.com/ZyCromerZ/Clang/releases/download/20.0.0git-20250129-release/Clang-20.0.0git-20250129.tar.gz
check_and_clone $GCC_ARM_DIR \
    https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9 \
        arm-linux-androideabi-4.9
check_and_clone $GCC_AARCH64_DIR \
    https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
        aarch64-linux-android-4.9

# Каталог для сборки MagicTime
MAGICTIME_DIR=$KERNEL_DIR/MagicTime-$DEVICE

# Создание каталога MagicTime, если его нет
if [ ! -d $MAGICTIME_DIR ]; then
    mkdir -p $MAGICTIME_DIR
    
    # Проверка и клонирование Anykernel, если MagicTime не существует
    if [ ! -d $MAGICTIME_DIR/Anykernel ]; then
        git clone https://github.com/TIMISONG-dev/Anykernel.git \
            $MAGICTIME_DIR/Anykernel
        
        # Перемещение всех файлов из Anykernel в MagicTime
        mv $MAGICTIME_DIR/Anykernel/* $MAGICTIME_DIR/
        
        # Удаление папки Anykernel
        rm -rf $MAGICTIME_DIR/Anykernel
    fi
else
    # Если папка MagicTime существует, проверить наличие .git и удалить, если есть
    if [ -d $MAGICTIME_DIR/.git ]; then
        rm -rf $MAGICTIME_DIR/.git
    fi
fi

# Экспорт переменных среды
if [ $DEVICE = pipa ]; then
    IMGPATH=$MAGICTIME_DIR/kernels/Image
    DTBPATH=$MAGICTIME_DIR/kernels/dtb
    DTBOPATH=$MAGICTIME_DIR/kernels/dtbo.img
else
    IMGPATH=$MAGICTIME_DIR/Image
    DTBPATH=$MAGICTIME_DIR/dtb
    DTBOPATH=$MAGICTIME_DIR/dtbo.img
fi

# Установка переменных PATH
export PATH=$CLANG_DIR/bin:$GCC_AARCH64_DIR/bin:$GCC_ARM_DIR/bin:$PATH
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
export KBUILD_BUILD_USER=TIMISONG
export KBUILD_BUILD_HOST=timisong-dev

# Запись времени сборки
MAGIC_BUILD_DATE=$(date '+%Y-%m-%d_%H-%M-%S')

# Каталог для результатов сборки
OUT_DIR=out

# Конфигурация ядра
make O="$OUT_DIR" \
            ${DEVICE}_defconfig \
            vendor/xiaomi/magictime-common.config

    # Компиляция ядра
    make -j $(nproc) \
                O="$OUT_DIR" \
                CC="ccache clang" \
                HOSTCC=gcc \
                LD=ld.lld \
                AS=llvm-as \
                AR=llvm-ar \
                NM=llvm-nm \
                OBJCOPY=llvm-objcopy \
                OBJDUMP=llvm-objdump \
                STRIP=llvm-strip \
                LLVM=1 \
                LLVM_IAS=1 \
                V=$VERBOSE 2>&1 | tee build.log
                

# Предполагается, что переменная DTS установлена ранее в скрипте
find $DTS -name '*.dtb' -exec cat {} + > $DTBPATH
find $DTS -name 'Image' -exec cat {} + > $IMGPATH
find $DTS -name 'dtbo.img' -exec cat {} + > $DTBOPATH

# Завершение отсчета времени выполнения скрипта
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))

cd "$KERNEL_PATH"

# Проверка успешности сборки
if grep -q -E "Ошибка 2|Error 2" build.log; then
    cd $KERNEL_PATH
    echo Ошибка: Сборка завершилась с ошибкой

    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendMessage \
    -d chat_id=@magictimekernel \
    -d text="Ошибка в компиляции!" \
    -d message_thread_id=38153

    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=@magictimekernel \
    -F document=@./build.log \
    -F message_thread_id=38153

    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=@magictimekernel \
    -F document=@../changelog.txt \
    -F message_thread_id=38153
else
    echo Общее время выполнения: $elapsed_time секунд
    # Перемещение в каталог MagicTime и создание архива
    cd $MAGICTIME_DIR
    7z a -mx9 MagicTime-$DEVICE-$MAGIC_BUILD_DATE.zip * -x!*.zip
    
    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendMessage \
    -d chat_id=@magictimekernel \
    -d text="Компиляция завершилась успешно! Время выполнения: $elapsed_time секунд" \
    -d message_thread_id=38153

    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=@magictimekernel \
    -F document=@./MagicTime-$DEVICE-$MAGIC_BUILD_DATE.zip \
    -F caption="MagicTime ${VERSION}${PREFIX}${BUILD} (${DESC}) branch: ${BRANCH}" \
    -F message_thread_id=38153
    
    curl -s -X POST https://api.telegram.org/bot$TGTOKEN/sendDocument?chat_id=@magictimekernel \
    -F document=@../changelog.txt \
    -F caption="Latest changes" \
    -F message_thread_id=38153

    rm -rf MagicTime-$DEVICE-$MAGIC_BUILD_DATE.zip

    BUILD=$((BUILD + 1))

    cd $KERNEL_PATH
    LAST=$(git log -1 --format=%H)

    sed -i "s/LAST=.*/LAST=$LAST/" ../settings.sh
    sed -i "s/BUILD=.*/BUILD=$BUILD/" ../settings.sh
fi