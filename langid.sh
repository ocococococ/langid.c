#!/bin/sh
#
# langid.sh - a portable shell + awk port of the langid.c command-line tool.
#
# Implements the same classifier as liblangid.c (byte n-gram tokenizer +
# multinomial naive Bayes) and gives the same answers, using only POSIX sh,
# awk and od. It is much slower than the compiled tool.
#
# Run `langid.sh -h` for usage.

AWK=${AWK:-awk}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# model.c -> text model
# ---------------------------------------------------------------------------
CONVERT_AWK='
# body of a C initializer: the text between the first "{" and the last "}"
function body(line,   a, b) {
  a = index(line, "{"); b = length(line)
  while (b > a && substr(line, b, 1) != "}") b--
  return substr(line, a + 1, b - a - 1)
}
/^unsigned tk_nextmove/ { nm = body($0) }
/^unsigned tk_output_c/ { oc = body($0) }
/^unsigned tk_output_s/ { os = body($0) }
/^unsigned tk_output\[/ { ot = body($0) }
/^double nb_pc/         { pc = body($0) }
/^double nb_ptc/        { ptc = body($0) }
/^char \*nb_classes/    { cl = body($0) }
END {
  if (nm == "" || pc == "" || ptc == "" || cl == "") {
    print "langid.sh: not a langid.c model.c file" > "/dev/stderr"
    exit 1
  }
  nl = split(pc, pcv, ",")
  ns = split(substr(nm, 2, length(nm) - 2), rows, /\},\{/)
  nf = split(ptc, ptcv, ",") / nl
  gsub(/"/, "", cl); gsub(/,/, " ", cl)
  print "langid-text-model 1"
  print "M " nf " " nl " " ns
  print "L " cl
  gsub(/,/, " ", pc); print "P " pc
  for (i = 1; i <= ns; i++) { gsub(/,/, " ", rows[i]); print "T " rows[i] }
  split(oc, ocv, ","); split(os, osv, ","); split(ot, otv, ",")
  for (i = 1; i <= ns; i++) if (ocv[i] > 0) {
    line = "O " (i - 1)
    for (j = 1; j <= ocv[i]; j++) line = line " " otv[osv[i] + j]
    print line
  }
  for (f = 0; f < nf; f++) {
    line = "F " ptcv[f * nl + 1]
    for (j = 2; j <= nl; j++) line = line " " ptcv[f * nl + j]
    print line
  }
}'

# ---------------------------------------------------------------------------
# classifier
#
# Input is a stream of od(1) lines (byte values, starting with a blank) and
# marker lines from the shell:  B path (begin file)  E (end of document)
#                               X path (cannot open)  D path (not a file)
# ---------------------------------------------------------------------------
CLASSIFY_AWK='
BEGIN {
  ns = nf = nl = 0
  while ((rc = getline line < model) > 0) {
    t = substr(line, 1, 1)
    if (t == "T") T[ns++] = substr(line, 3)
    else if (t == "F") F[nf++] = substr(line, 3)
    else if (t == "O") {
      n = split(line, a, " ")
      oc[a[2]] = n - 2
      for (j = 3; j <= n; j++) ov[a[2], j - 3] = a[j]
    }
    else if (t == "P") nl = split(substr(line, 3), pc, " ")
    else if (t == "L") split(substr(line, 3), cls, " ")
    else if (t == "M") split(line, hdr, " ")
    else if (line != "langid-text-model 1") { rc = -2; break }
  }
  close(model)
  if (rc == -1) { print "unable to open: " model > "/dev/stderr"; failed = 1; exit 255 }
  if (rc == -2 || nl == 0 || ns != hdr[4] || nf != hdr[2] || nl != hdr[3]) {
    print "error loading model from: " model > "/dev/stderr"; failed = 1; exit 255
  }
  reset()
  if (mode == "i") { print "langid.c interactive mode."; prompt() }
}

function prompt() { printf ">>> "; fflush() }

function reset() {
  s = 0; len = 0; svn = 0
  split("", svc); split("", svk)
}

# Next-state rows are split on demand, the first time a state is entered.
function loadrow(st,   r, k) {
  split(T[st], r, " ")
  for (k = 0; k < 256; k++) nm[st, k] = r[k + 1]
  loaded[st] = 1
}

# Mirrors liblangid.c: the sparse sets keep keys in first-insertion order,
# which fixes the order of the floating-point sums.
function classify(   i, j, st, c, f, w, fvn, fvk, fvc, lp, m) {
  fvn = 0
  for (i = 0; i < svn; i++) {
    st = svk[i]; c = svc[st]
    if (!(st in oc)) continue
    for (j = 0; j < oc[st]; j++) {
      f = ov[st, j]
      if (f in fvc) fvc[f] += c
      else { fvk[fvn++] = f; fvc[f] = c }
    }
  }
  for (j = 1; j <= nl; j++) lp[j] = pc[j] + 0
  for (i = 0; i < fvn; i++) {
    f = fvk[i]; c = fvc[f]
    split(F[f], w, " ")
    for (j = 1; j <= nl; j++) lp[j] += c * w[j]
  }
  m = 1
  for (j = 2; j <= nl; j++) if (lp[m] < lp[j]) m = j
  return cls[m]
}

function emit(   lang) {
  lang = classify()
  if (mode == "b") print name "," len "," lang
  else print lang "," len
  if (mode == "i") prompt()
  reset()
}

{
  t = substr($0, 1, 1)
  if (t == "B") { name = substr($0, 3); next }
  if (t == "E") { emit(); next }
  if (t == "X") { print substr($0, 3) ",0,NOSUCHFILE"; next }
  if (t == "D") { print substr($0, 3) ",0,NOTAFILE"; next }
  for (i = 1; i <= NF; i++) {
    b = $i
    if (!(s in loaded)) loadrow(s)
    s = nm[s, b]
    if (s in svc) svc[s]++
    else { svk[svn++] = s; svc[s] = 1 }
    len++
    if (mode == "l" && b == 10) emit()
  }
}

END {
  if (failed) exit 255
  if (mode == "f" || (mode == "l" && len > 0)) emit()
  if (mode == "i") print "Bye!"
}'

die() {
  echo "$*" >&2
  exit 255
}

usage() {
  cat <<'USAGE'
Usage: langid.sh [-l | -b] [-m MODEL]
       langid.sh --convert MODEL_C [OUTPUT]
       langid.sh -h

Identify the language of text read from stdin.

Modes:
  (default)   read all of stdin as one document; print "lang,length"
  -l          line mode: classify each line of stdin; print "lang,length"
  -b          batch mode: stdin lists file paths, one per line;
              print "path,length,lang" (NOSUCHFILE / NOTAFILE on errors)
  (terminal)  when stdin is a terminal, prompt for lines interactively;
              an empty line or Ctrl-D quits

Options:
  -m MODEL    use a text model, made by `ldpy2ldc.py --text` or --convert
              (default: the model compiled into langid.c, from model.c)
  -h, --help  show this help and exit
  --convert MODEL_C [OUTPUT]
              convert a langid.c model.c into a text model, written to
              OUTPUT or stdout

The length is the number of bytes read, including the newline in line mode.

Without -m, model.c next to this script is converted on first use to
ldpy.tmodel (a few seconds, one-time), stored next to this script or, if
that directory is not writable, in ${XDG_CACHE_HOME:-~/.cache}/langid.sh/.

Environment:
  AWK         awk implementation to use (default: awk; mawk is fastest)

Examples:
  echo "Bonjour tout le monde" | langid.sh
  langid.sh -l < sentences.txt
  ls *.txt | langid.sh -b
USAGE
}

# convert MODEL_C OUTPUT: write the text model atomically
convert() {
  tmp="$2.tmp.$$"
  if "${AWK}" "${CONVERT_AWK}" "$1" >"${tmp}"; then
    mv -f "${tmp}" "$2"
  else
    rm -f "${tmp}"
    return 1
  fi
}

# Locate (building it if needed) the text model for the in-built model.c
default_model() {
  src="${SCRIPT_DIR}/model.c"
  for dir in "${SCRIPT_DIR}" "${XDG_CACHE_HOME:-${HOME}/.cache}/langid.sh"; do
    if [ -f "${dir}/ldpy.tmodel" ] && ! [ "${src}" -nt "${dir}/ldpy.tmodel" ]; then
      echo "${dir}/ldpy.tmodel"
      return 0
    fi
  done
  [ -f "${src}" ] || die "langid.sh: no model given (-m) and ${src} not found"
  for dir in "${SCRIPT_DIR}" "${XDG_CACHE_HOME:-${HOME}/.cache}/langid.sh"; do
    mkdir -p "${dir}" 2>/dev/null
    if [ -w "${dir}" ]; then
      echo "langid.sh: building ${dir}/ldpy.tmodel from model.c (one-time)..." >&2
      convert "${src}" "${dir}/ldpy.tmodel" || die "langid.sh: model conversion failed"
      echo "${dir}/ldpy.tmodel"
      return 0
    fi
  done
  die "langid.sh: no writable location for the converted model"
}

# ---------------------------------------------------------------------------
# command line
# ---------------------------------------------------------------------------
if [ "$1" = "--help" ]; then
  usage
  exit 0
fi

if [ "$1" = "--convert" ]; then
  [ $# -ge 2 ] || die "usage: langid.sh --convert MODEL_C [OUTPUT]"
  if [ $# -ge 3 ]; then convert "$2" "$3"; else "${AWK}" "${CONVERT_AWK}" "$2"; fi
  exit
fi

l_flag=0 b_flag=0 model=""
while getopts ":lbm:h" opt; do
  case ${opt} in
  l) l_flag=1 ;;
  b) b_flag=1 ;;
  m) model=${OPTARG} ;;
  h)
    usage
    exit 0
    ;;
  :)
    echo "Option -${OPTARG} requires an argument." >&2
    echo "Try 'langid.sh -h' for help." >&2
    exit 1
    ;;
  *)
    echo "Unknown option \`-${OPTARG}'." >&2
    echo "Try 'langid.sh -h' for help." >&2
    exit 1
    ;;
  esac
done

[ "${l_flag}" = 1 ] && [ "${b_flag}" = 1 ] && die "Cannot specify both -l and -b."

if [ -z "${model}" ]; then
  model=$(default_model) || exit
fi

classify() { "${AWK}" -v model="${model}" -v mode="$1" "${CLASSIFY_AWK}"; }

if [ -t 0 ]; then
  # interactive: one awk process, fed a line at a time
  while IFS= read -r line && [ -n "${line}" ]; do
    printf '%s\n' "${line}" | od -An -v -tu1
    echo E
  done | classify i
elif [ "${l_flag}" = 1 ]; then
  od -An -v -tu1 | classify l
elif [ "${b_flag}" = 1 ]; then
  while IFS= read -r path || [ -n "${path}" ]; do
    if [ -d "${path}" ]; then
      printf 'D %s\n' "${path}"
    elif [ -r "${path}" ]; then
      printf 'B %s\n' "${path}"
      od -An -v -tu1 <"${path}"
      echo E
    else
      printf 'X %s\n' "${path}"
    fi
  done | classify b
else
  od -An -v -tu1 | classify f
fi
