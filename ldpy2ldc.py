"""
Repack the Python model into a form that langid.c can read.

Works with both Python 2.7 and Python 3.

Marco Lui, July 2014
"""

from __future__ import print_function

import argparse
import array
import base64
import bz2
import pickle
import sys
from itertools import islice

import langid.langid as langid

PY3 = sys.version_info[0] >= 3


def _py2_array(typecode, data=b''):
  """
  Python 2 pickles array.array as (typecode, raw byte string). Unpickled with
  encoding='latin1' on Python 3, the byte string arrives as str, which
  array.array() rejects. latin1 maps code points 0-255 back to the same bytes.
  """
  if isinstance(typecode, bytes):
    typecode = typecode.decode('ascii')
  if isinstance(data, str) and PY3:
    data = data.encode('latin1')
  if isinstance(data, list):
    return array.array(typecode, data)
  a = array.array(typecode)
  if hasattr(a, 'frombytes'):
    a.frombytes(data)
  else:
    a.fromstring(data)
  return a


if PY3:
  class _ModelUnpickler(pickle.Unpickler):
    def find_class(self, module, name):
      if module == 'array' and name == 'array':
        return _py2_array
      return pickle.Unpickler.find_class(self, module, name)


def load_identifier(path):
  """
  Load a langid.py model file. langid.py's own loader cannot read models that
  were pickled under Python 2 (such as the bundled ldpy.model) when running
  under Python 3, so we decode the model ourselves in that case.
  """
  if not PY3:
    return langid.LanguageIdentifier.from_modelpath(path)

  import io
  import numpy as np

  with open(path, 'rb') as f:
    raw = bz2.decompress(base64.b64decode(f.read()))
  model = _ModelUnpickler(io.BytesIO(raw), encoding='latin1').load()
  nb_ptc, nb_pc, nb_classes, tk_nextmove, tk_output = model
  nb_numfeats = int(len(nb_ptc) / len(nb_pc))
  nb_classes = [as_text(c) for c in nb_classes]
  nb_pc = np.array(nb_pc)
  nb_ptc = np.array(nb_ptc).reshape(nb_numfeats, len(nb_pc))
  return langid.LanguageIdentifier(nb_ptc, nb_pc, nb_numfeats, nb_classes, tk_nextmove, tk_output)

model_template = """\
#include "model.h"

unsigned tk_nextmove[NUM_STATES][256] = {tk_nextmove};
unsigned tk_output_c[NUM_STATES] = {tk_output_c};
unsigned tk_output_s[NUM_STATES] = {tk_output_s};
unsigned tk_output[] = {tk_output};
double nb_pc[NUM_LANGS] = {nb_pc};
double nb_ptc[{nb_ptc_size}] = {nb_ptc};
char *nb_classes[NUM_LANGS] = {nb_classes};
"""

header_template = """\
#ifndef _MODEL_H
#define _MODEL_H

#define NUM_FEATS {num_feats}
#define NUM_LANGS {num_langs}
#define NUM_STATES {num_states}

extern unsigned tk_nextmove[NUM_STATES][256];
extern unsigned tk_output_c[NUM_STATES];
extern unsigned tk_output_s[NUM_STATES];
extern unsigned tk_output[];
extern double nb_pc[NUM_LANGS];
extern double nb_ptc[{nb_ptc_size}];
extern char *nb_classes[NUM_LANGS];

#endif
"""

def pack_tk_output(ident):
  num_states = len(ident.tk_nextmove) >> 8

  # tk_output is a mapping from state to list of feats completed by entering that state.
  # we encode it as a single array of 2-byte values. each "entry" is a state label,
  # a number representing a count followed by count featlabels
  tk_output_c = []
  tk_output_s = []
  tk_output = []
  for i in range(num_states):
    if i in ident.tk_output and ident.tk_output[i]:
      count = len(ident.tk_output[i])
      feats = ident.tk_output[i]
    else:
      count = 0
      feats = []

    tk_output_c.append(count)
    tk_output_s.append(len(tk_output))
    tk_output.extend(int(f) for f in feats)
  return tk_output_c, tk_output_s, tk_output

def c_literal(x):
  """
  Format a number for a C initializer. Floats are formatted the way Python 2's
  str() did (12 significant digits, trailing '.0' on integral values), so that
  the generated model.c is identical whichever Python version produces it.
  """
  if hasattr(x, 'item'):  # numpy scalar -> Python scalar
    x = x.item()
  if isinstance(x, float):
    s = '%.12g' % x
    if s.lstrip('-').isdigit():
      s += '.0'
    return s
  return str(x)

def as_c_array_init(seq):
  return "{" + ",".join(c_literal(x) for x in seq) + "}"

def chunk(seq, chunksize):
  """
  Break a sequence into chunks not exceeeding a predetermined size
  """
  seq_iter = iter(seq)
  while True:
    chunk = tuple(islice(seq_iter, chunksize))
    if not chunk: break
    yield chunk

def text_model(ident, num_feats, num_langs, num_states):
  """
  Line-based model format read by langid.sh. One record per line, tagged by
  its first character:
    M num_feats num_langs num_states
    L class labels
    P class priors (nb_pc)
    T 256 next states        (one line per state, in state order)
    O state feat feat ...    (features completed on entering a state)
    F num_langs weights      (one line per feature, in feature order: nb_ptc)
  """
  tk_output_c, tk_output_s, tk_output = pack_tk_output(ident)
  lines = ["langid-text-model 1",
           "M {} {} {}".format(num_feats, num_langs, num_states),
           "L " + " ".join(as_text(c) for c in ident.nb_classes),
           "P " + " ".join(c_literal(x) for x in ident.nb_pc)]
  lines.extend("T " + " ".join(str(x) for x in row) for row in chunk(ident.tk_nextmove, 256))
  for state in range(num_states):
    count, start = tk_output_c[state], tk_output_s[state]
    if count:
      lines.append("O {} ".format(state) + " ".join(str(f) for f in tk_output[start:start + count]))
  lines.extend("F " + " ".join(c_literal(x) for x in row) for row in ident.nb_ptc)
  return "\n".join(lines) + "\n"

def as_text(c):
  """
  Class labels may be bytes (models pickled under Python 2) or str.
  """
  if isinstance(c, bytes):
    return c.decode('utf-8')
  return u'{}'.format(c)


if __name__ == "__main__":
  parser = argparse.ArgumentParser()
  parser.add_argument("--output", "-o", help="write exported model to (default: stdout)")
  parser.add_argument("--header", action="store_true", help="produce header file")
  parser.add_argument("--protobuf", action="store_true", help="produce model in protocol buffer format")
  parser.add_argument("--text", action="store_true", help="produce model in the line-based text format read by langid.sh")
  parser.add_argument("model", help="read model from")
  args = parser.parse_args()

  if args.protobuf + args.header + args.text > 1:
    parser.error("can only specify one of --protobuf, --header or --text")

  ident = load_identifier(args.model)

  # diagnostics go to stderr so that writing the model to stdout stays clean
  log = sys.stderr
  print("NB_PTC", type(ident.nb_ptc), ident.nb_ptc.shape, ident.nb_ptc.dtype, file=log)
  print("NB_PC", type(ident.nb_pc), ident.nb_pc.shape, ident.nb_pc.dtype, file=log)
  print("NB_NUMFEATS", type(ident.nb_numfeats), ident.nb_numfeats, file=log)
  print("NB_CLASSES", type(ident.nb_classes), len(ident.nb_classes), file=log)
  print("TK_NEXTMOVE", type(ident.tk_nextmove), len(ident.tk_nextmove), ident.tk_nextmove.typecode, ident.tk_nextmove.itemsize, file=log)
  print("TK_OUTPUT", type(ident.tk_output), len(ident.tk_output), file=log)
  print(file=log)

  num_feats, num_langs = ident.nb_ptc.shape
  num_states = len(ident.tk_nextmove) >> 8
  nb_ptc_size = num_feats * num_langs

  if args.protobuf:
    import langid_pb2

    tk_output_c, tk_output_s, tk_output = pack_tk_output(ident)

    lid = langid_pb2.LanguageIdentifier()

    # basic parameters
    lid.num_feats = num_feats
    lid.num_langs = num_langs
    lid.num_states = num_states

    # pack the tokenizer
    lid.tk_nextmove.extend(ident.tk_nextmove)
    lid.tk_output_c.extend(tk_output_c)
    lid.tk_output_s.extend(tk_output_s)
    lid.tk_output.extend(tk_output)

    # pack the classifier parameters
    lid.nb_pc.extend(ident.nb_pc.tolist())
    lid.nb_ptc.extend(ident.nb_ptc.ravel().tolist())

    # pack the class labels
    lid.nb_classes.extend(as_text(c) for c in ident.nb_classes)

    data = lid.SerializeToString()
    if args.output:
      with open(args.output, 'wb') as f:
        f.write(data)
    else:
      getattr(sys.stdout, 'buffer', sys.stdout).write(data)

  else:
    if args.header:
      text = header_template.format(**locals())
    elif args.text:
      text = text_model(ident, num_feats, num_langs, num_states)
    else:
      # chunk tk_nextmove back into length-256 array initializers, to avoid C warnings
      # about initialization mismatches
      tk_nextmove = "{" + ",".join(as_c_array_init(c) for c in chunk(ident.tk_nextmove, 256)) + "}"

      tk_output_c, tk_output_s, tk_output = pack_tk_output(ident)
      tk_output_c = as_c_array_init(tk_output_c)
      tk_output_s = as_c_array_init(tk_output_s)
      tk_output = as_c_array_init(tk_output)

      nb_pc = as_c_array_init(ident.nb_pc)
      nb_ptc = as_c_array_init(ident.nb_ptc.ravel())
      nb_classes = "{" + ",".join('"{}"'.format(as_text(c)) for c in ident.nb_classes) + "}"

      text = model_template.format(**locals())

    if args.output:
      with open(args.output, 'w') as f:
        f.write(text)
    else:
      sys.stdout.write(text)
