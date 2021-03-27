#!/bin/bash
set -eu

now() { date +%s; }
S=$(now)
vecho() { ${vecho-:} "$@"; }
executable_p() { command -v "$1" >/dev/null 2>&1; }
dgst='cksum "$@" | while read d _; do printf $d; done'
! executable_p b3sum || dgst='b3sum --no-names "$@"'
executable_p realpath || realpath() (cd "$1" &>/dev/null; pwd -P)
eval "digest() { $dgst; } 2>/dev/null"
die() { echo "$@" >&2; exit 111; }
trap 'echo "$(test $? -eq 0 || echo "fail ")$(($(now) - $S)) sec"' EXIT

darwin=false
wsid="wsi/x11"
clip="LC_CTYPE=UTF-8 xclip -i"
paste="LC_CTYPE=UTF-8 xclip -o"
uopen="echo 'Open "%s"' >&2"
print="echo 'Print "%s"' >&2"
mjobs=$(getconf _NPROCESSORS_ONLN || echo 1)
case "$(uname)" in
    Darwin)
        darwin=true
        wsid="wsi/cocoa"
        clip="LC_CTYPE=UTF-8 pbcopy"
        paste="LC_CTYPE=UTF-8 pbaste"
        uopen='open "%s"';;
    Linux) ;;
    *) die $(uname) is not supported;;
esac

test -n "${1-}" || die "usage: $0 build-directory"

outd="$1"
srcd="$(dirname $0)"
mudir=$outd/mupdf
muinc="-I $mudir/include -I $mudir/thirdparty/freetype/include"

test -d "$mudir" || die muPDF not found, consult $(dirname $0)/BUILDING

mkdir -p $outd/{$wsid,lablGL}

isfresh() { test -r $1.past && test "$(<$1.past)" = "$2"; }

mbt=${mbt:-release}
mulibs="$mudir/build/$mbt/libmupdf.a $mudir/build/$mbt/libmupdf-third.a"
make="make -C "$mudir" build=$mbt -j $mjobs libs"
$make -q -s || $make

oincs() {
    local b=$1 incs
    case "${2#$outd/}" in
        $wsid/wsi.cm[io]|confstruct.cmo|help.cmo) incs="-I $b -I $b/$wsid";;
        glutils.cmo) incs="-I $b -I $b/lablGL";;
        uiutils.cmo|main.cmo) incs="-I $b -I $b/$wsid -I $b/lablGL";;
        ffi.cmo|help.cmi|parser.cmo) incs="-I $b";;
        config.cmo) incs="-I $b -I $b/$wsid -I $outd";;
        lablGL/*) incs="-I $b/lablGL";;
        main.cmi|keys.cmo|utils.cmo|utf8syms.cmo) ;;
        *) die "ocaml include paths for '$2' aren't set";;
    esac
    test -z "${incs-}" || echo $incs
}

oflags() {
    case "${1#$outd/}" in
        lablGL/*) f="-g";;
        *) f="-g -strict-sequence -strict-formats -alert @all -warn-error @A";;
    esac
    echo "$(oincs $outd $1) $f"
}

cflags() {
    case "${1#$outd/}" in
        version.o) f=-DLLPP_VERSION=$ver;;
        lablGL/*.o) f="-g -Wno-pointer-sign -Werror -O2";;
        link.o)
            f="-g -std=c11 $muinc -Wall -Werror -Wextra -pedantic "
            test "${mbt-}" = "debug" || f+="-O2 "
            $darwin && f+="-DMACOS -D_GNU_SOURCE -DGL_H='<OpenGL/gl.h>'" \
                    || f+="-D_POSIX_C_SOURCE -DGL_H='<GL/gl.h>'"
            f+=" -include $srcd/diag.h -DFIXME=0"
            f+=" -DTEXT_TYPE=GL_TEXTURE_RECTANGLE_ARB"
            #f+=" -DTEXT_TYPE=GL_TEXTURE_2D"
            ;;
        *) f="-g -O2 -Wall -Werror";;
    esac
    ! $darwin || f+=" -DGL_SILENCE_DEPRECATION"
    echo $f
}

mflags() {
    echo "-I $(ocamlc -where) -g -Wall -Werror -O2 -DGL_SILENCE_DEPRECATION"
}

overs="$(ocamlc -vnum 2>/dev/null)" || overs=""
if test "$overs" != "4.12.0"; then
    url=https://caml.inria.fr/pub/distrib/ocaml-4.12/ocaml-4.12.0.tar.xz
    txz=$outd/$(basename $url)
    keycmd="printf $url; digest $txz;"
    isfresh $txz "$(eval $keycmd)" || {
        if executable_p wget; then dl() { wget -q "$1" -O "$2"; }
        elif executable_p curl; then dl() { curl -L "$1" -o "$2"; }
        else die "no program to fetch remote urls found"
        fi
        dl $url $txz
        eval $keycmd >$txz.past
    } && vecho "fresh $txz"
    absprefix=$(realpath $outd)
    export PATH=$absprefix/bin:$PATH
    ocamlc=$absprefix/bin/ocamlc
    keycmd="printf $url; digest $ocamlc;"
    isfresh $ocamlc "$(eval $keycmd)" || (
        # This will needlessly re{configure,make} ocaml since "past"
        # of configure/make is hard to ascertain. "Better safe than
        # sorry" approach is taken here. The check will work for a
        # single ocaml url/version, but _will_ redo everything
        # otherwise (even if fully built artifacts are available)
        tar xf $txz -C $outd
        bn=$(basename $url)
        cd $outd/${bn%.tar.xz}
        ./configure --disable-ocamldoc --disable-ocamltest      \
                    --enable-debugger=no --prefix=$absprefix
        make -j $mjobs world
        make install
        eval $keycmd >$absprefix/bin/ocamlc.past
    ) && vecho "fresh ocamlc"
    overs=$(ocamlc -vnum 2>/dev/null)
fi

while read k v; do
    case "$k" in
        "bytecomp_c_compiler:") ccomp=${CAML_CC-$v};;
        "word_size:") ! test "$darwin$v" = "true32" || die "need 64bit ocaml";;
    esac
done < <(ocamlc -config)

read cvers < <($ccomp --version)

seen=
ord=
bocaml1() {
    expr >/dev/null "$seen" : ".*$3" || {
        bocaml2 "$@"
        test "${3%.cmi}" != "$3" || ord+="$3 "
        seen+="$3"
    }
}

bocaml2() {
    local n=$1 s="$2" o="$3" deps= cmd d
    local keycmd="digest $s $o.depl"
    cmd="ocamlc -depend -bytecode -one-line $(oincs $srcd $o) $s"

    isfresh "$o.depl" "$overs$cmd$(eval $keycmd)" || {
        read _ _ depl < <(eval $cmd) || die "$cmd failed"
        for d in $depl; do
            if test "$d" = "$outd/confstruct.cmo";
            then d=confstruct.cmo; else d=${d#$srcd/}; fi
            test "${o%.cmo}.cmi" = "$outd/$d" || deps+="$d\n"
        done
        printf "$deps" >$o.depl
        deps=
        echo "$overs$cmd$(eval $keycmd)" >"$o.depl.past"
    } && vecho "fresh $o.depl"

    while read d; do
        bocaml $d $((n+1));
        deps+=" $outd/$d"
    done <$o.depl

    cmd="ocamlc $(oflags $o) -c -o $o $s"
    keycmd="digest $o $s $deps"
    isfresh "$o" "$overs$cmd$(eval $keycmd)" || {
        printf "%*.s%s\n" $n '' "${o#$outd/}"
        eval "$cmd" || die "$cmd failed"
        echo "$overs$cmd$(eval $keycmd)" >"$o.past"
    } && vecho "fresh $o"
}

cycle=
bocaml() {
    local s o="$1" n="$2" cycle1="$cycle" cmi=false
    local wocmi="${o%.cmi}"
    case $o in
        confstruct.cmo)
            s=$outd/confstruct.ml
            o=$outd/confstruct.cmo;;
        *)
            if test "$o" = "$wocmi"; then s=$srcd/${o%.cmo}.ml; else
                cmi=true
                s=$srcd/$wocmi.mli
            fi
            o=$outd/$o;;
    esac
    expr >/dev/null "$cycle" : ".*$o" && die cycle $o || cycle="$cycle$o"
    bocaml1 $n $s $o
    ! $cmi || bocaml1 $n "${s%.mli}.ml" "$outd/${wocmi}.cmo"
    cycle=$cycle1
}

bocamlc() {
    local o=$outd/$1
    local s=$srcd/${1%.o}.c
    local cc=${CAML_CC:+-cc "'$CAML_CC'" }
    local cmd="ocamlc $cc-ccopt \"$(cflags $o) -MMD -MF $o.dep -MT_ -o $o\" $s"
    { read _ d <$o.dep; } 2>/dev/null || d=
    local keycmd='digest $o $d'
    isfresh "$o" "$cvers$cmd$(eval $keycmd)" || {
        echo "${o#$outd/}"
        eval "$cmd" || die "$cmd failed"
        read _ d <$o.dep
        echo "$cvers$cmd$(eval $keycmd)" >"$o.past"
    } && vecho "fresh $o"
}

bobjc() {
    local o=$outd/$1
    local s=$srcd/${1%.o}.m
    local cmd="$mcomp $(mflags $o) -MD -MF $o.dep -MT_ -c -o $o $s"
    test -r $o.dep && read _ d <$o.dep || d=
    local keycmd='digest $o $d'
    isfresh "$o" "$cmd$(eval $keycmd)" || {
        echo "${o#$outd/}"
        eval "$cmd" || die "$cmd failed"
        read _ d <$o.dep
        echo "$cmd$(eval $keycmd)" >"$o.past"
    } && vecho "fresh $o"
}

ver=$(cd $srcd && git describe --tags --dirty) || ver="'built on $(date)'"

gen=$srcd/genconfstruct.sh
cmd="(export print paste clip uopen; . $gen >$outd/confstruct.ml)"
keycmd="{ echo '$print $paste $clip $uopen'; digest $gen $outd/confstruct.ml; }"
isfresh "$outd/confstruct.ml" "$cmd$(eval $keycmd)" || {
    echo "generating $outd/confstruct.ml"
    eval "$cmd" || die $gen failed
    echo "$cmd$(eval $keycmd)" > "$outd/confstruct.ml.past"
} && vecho "fresh $outd/confstruct.ml"

shift 1
for target; do
    case "$target" in
        doc)
            md=$outd/doc
            mkdir -p $md
            for m in llpp llppac llpphtml; do
                src=$srcd/adoc/$m.adoc
                o=$md/$m.1
                conf="$srcd/man/asciidoc.conf"
                keycmd="digest $o $src $conf"
                cmd="a2x -f manpage -D $md $src"
                isfresh "$o" "$cmd$(eval $keycmd)" || {
                    echo "${o#$outd/}"
                    eval "$cmd" || die "$cmd failed"
                    echo "$cmd$(eval $keycmd)" >"$o.past"
                } && vecho "fresh $o"
            done;
            exit;;
        *) die "no such target - '$target'";;
    esac
done

bocaml main.cmi 0

cobjs=
for m in link cutils version; do
    bocamlc $m.o
    cobjs+=" $outd/$m.o"
done
for m in ml_gl ml_glarray ml_raw; do
    bocamlc lablGL/$m.o
    cobjs+=" $outd/lablGL/$m.o"
done

libs="str.cma unix.cma"
clibs="-L$mudir/build/$mbt -lmupdf -lmupdf-third -lpthread"
if $darwin; then
    mcomp=$ccomp
    clibs+=" -framework Cocoa -framework OpenGL"
    cobjs+=" $outd/wsi/cocoa/cocoa.o"
    bobjc wsi/cocoa/cocoa.o
else
    clibs+=" -lGL -lX11"
    cobjs+=" $outd/wsi/x11/keysym2ucs.o $outd/wsi/x11/xlib.o"
    bocamlc wsi/x11/keysym2ucs.o
    bocamlc wsi/x11/xlib.o
fi

cmd="ocamlc -custom $libs -o $outd/llpp $cobjs $ord -cclib \"$clibs\""
keycmd="digest $outd/llpp $cobjs $ord $mulibs"
isfresh "$outd/llpp" "$cmd$(eval $keycmd)" || {
    echo linking $outd/llpp
    eval "$cmd" || die "$cmd failed"
    echo "$cmd$(eval $keycmd)" >"$outd/llpp.past"
} && vecho "fresh llpp"

if $darwin; then
    out="$outd/llpp.app/Contents/Info.plist"
    keycmd="digest $out $srcd/wsi/cocoa/genplist.sh; echo $ver"
    isfresh $out "$(eval $keycmd)" || {
        d=$(dirname $out)
        mkdir -p "$d"
        echo "generating $out"
        (. $srcd/wsi/cocoa/genplist.sh) >"$out"
        eval $keycmd>"$out.past"
    } && vecho "fresh plist"

    out=$outd/llpp.app/Contents/MacOS/llpp
    keycmd="digest $out $outd/llpp"
    isfresh $out "$(eval $keycmd)" || {
        echo "bundling $out"
        mkdir -p "$(dirname $out)"
        cp $outd/llpp $out
        eval $keycmd>"$out.past"
    } && vecho "fresh bundle"
fi
