/*
 * Python binding to liblangid
 * Based on a tutorial by Dan Foreman-Mackey
 * http://dan.iel.fm/posts/python-c-extensions/
 * and on the implementation of chromium-compact-language-detector by Mike McCandless
 * https://code.google.com/p/chromium-compact-language-detector
 *
 * Supports both Python 2 and Python 3.
 *
 * Marco Lui <saffsd@gmail.com>, September 2014
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include "liblangid.h"

/* Docstrings */
static char module_docstring[] =
    "This module provides an off-the-shelf language identifier.";
static char identify_docstring[] =
    "Identify the language of a piece of text (str or bytes).";

/* Available functions */
static PyObject *langid_identify(PyObject *self, PyObject *args);

/* Module specification */
static PyMethodDef module_methods[] = {
    {"identify", langid_identify, METH_VARARGS, identify_docstring},
    {NULL, NULL, 0, NULL}
};

/* Global LanguageIdentifier instance */
static LanguageIdentifier *identifier = NULL;

#if PY_MAJOR_VERSION >= 3
static struct PyModuleDef langid_module = {
    PyModuleDef_HEAD_INIT,
    "_langid",
    module_docstring,
    -1,
    module_methods
};

PyMODINIT_FUNC PyInit__langid(void)
{
    PyObject *m = PyModule_Create(&langid_module);
    if (m == NULL)
        return NULL;

    if (identifier == NULL)
        identifier = get_default_identifier();
    return m;
}
#else
PyMODINIT_FUNC init_langid(void)
{
    PyObject *m = Py_InitModule3("_langid", module_methods, module_docstring);
    if (m == NULL)
        return;

    if (identifier == NULL)
        identifier = get_default_identifier();
}
#endif

static PyObject *langid_identify(PyObject *self, PyObject *args)
{
    char *bytes;
    const char *lang;
    Py_ssize_t numBytes;

    /* "s#" accepts str (UTF-8 encoded on Python 3) as well as bytes */
    if (!PyArg_ParseTuple(args, "s#", &bytes, &numBytes))
        return NULL;

    if (numBytes > INT_MAX) {
        PyErr_SetString(PyExc_OverflowError, "text too long");
        return NULL;
    }

    /* Run our identifier */
    lang = identify(identifier, bytes, (int) numBytes);

    /* Build the output object */
    return Py_BuildValue("s", lang);
}
