#!/bin/sh

function print_help() {
    echo "csvdiff build"
    echo ""
    echo "usage ./build.sh [OPTIONs]"
    echo ""
    echo "options:"
    echo "        --help     print this help"
    echo "        --all      build for all platforms (output in bin with platform suffix)"
    echo "        --upx      compress binary with upx"
    echo "        --clean    delete .zig-cache, zig-out and files in bin"
    echo "        --test     run tests (before build)"
    echo "        --release  prepare release (all flags set)"
    echo ""
}

function exit_on_error() {
    if [ $? -ne 0 ]; then
        >&2 echo ""
        >&2 echo "an error occured, stopping build"
        >&2 echo ""
        exit 1
    fi
}

function exit_argument_error() {
    error=$1
    print_help
    >&2 echo "error: $error"
    >&2 echo ""
    exit 1
}

ALL="false"
UPX="false"
TEST="false"
CLEAN="false"
TESTS="false"
RELEASE="false"

while (( "$#" )); do
    case "$1" in
        -h | --help )   print_help; exit 0;;
        --all )         ALL="true"; shift;;
        --upx )         UPX="true"; shift;;
        --clean )       CLEAN="true"; shift;;
        --test )        TESTS="true"; shift;;
        --release )     CLEAN="true"; ALL="true"; UPX="true"; TESTS="true"; RELEASE="true"; shift;;
        * ) exit_argument_error "unknown command $1";;
    esac
done

if [ "$CLEAN" == "true" ]; then
    echo cleaning
    rm -fr zig-out .zig-cache >/dev/null 2>&1
    rm bin/* >/dev/null 2>&1
fi

if [ "$TESTS" == "true" ]; then
    echo testing
    zig test src/main.zig || exit_on_error
fi

NATIVE_SUFFIX=""
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    NATIVE_SUFFIX=".exe"
fi

function build_platform() {
    PLAT=$1
    SUFFIX=$2
    COMPILED_BIN=zig-out/bin/csvdiff${SUFFIX}

    EXE_NAME=bin/csvdiff-${PLAT}${SUFFIX}
    if [ "$PLAT" == "native" ]; then
        EXE_NAME=bin/csvdiff${SUFFIX}
    fi
    
    #compile
    echo building $PLAT
    rm -f $EXE_NAME
    zig build -Doptimize=ReleaseFast -Dtarget=${PLAT}

    #compress with UPX if requested, else copy
    if [ "$UPX" = "true" ]; then
        echo compressing $PLAT
        if [[ "$RELEASE" == "true" ]] && [[ "$PLAT" != "native" ]]; then        
            upx -qq --lzma $COMPILED_BIN
        else
            upx -qq --lzma -o $EXE_NAME $COMPILED_BIN
        fi
    else 
        cp $COMPILED_BIN $EXE_NAME
    fi

    #create release packages
    if [[ "$RELEASE" == "true" ]] && [[ "$PLAT" != "native" ]]; then
        echo packaging $PLAT
        if [ "$SUFFIX" == ".exe" ]; then 
            cd zig-out/bin/
            zip a ../../bin/csvdiff-${PLAT}.zip csvdiff.exe > /dev/null
            cd ../../
        else 
            tar -czf ./bin/csvdiff-${PLAT}.tgz -C zig-out/bin/ csvdiff
        fi
    fi
}

# build native
echo
build_platform "native" $NATIVE_SUFFIX

# build all
if [ "$ALL" = "true" ]; then
    echo
    build_platform "x86_64-windows" ".exe"
    echo
    build_platform "x86_64-linux"
    echo
    build_platform "aarch64-linux"
    echo
fi
