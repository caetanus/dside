// clang_c.d — minimal D bindings to the libclang C API (stable ABI).
// Only the subset the generator needs. Native calls => no Python cindex overhead.
module clang_c;

extern (C):

// --- opaque / value types --------------------------------------------------
alias CXIndex = void*;
alias CXTranslationUnit = void*;
alias CXClientData = void*;
alias CXFile = void*;

struct CXString { const(void)* data; uint private_flags; }
struct CXCursor { int kind; int xdata; const(void)*[3] data; }
struct CXType   { int kind; void*[2] data; }
struct CXSourceLocation { const(void)*[2] ptr_data; uint int_data; }
struct CXSourceRange { const(void)*[2] ptr_data; uint begin_int_data, end_int_data; }
struct CXUnsavedFile { const(char)* Filename; const(char)* Contents; ulong Length; }

enum CXChildVisitResult { Break, Continue, Recurse }
alias CXCursorVisitor = extern (C) CXChildVisitResult function(CXCursor, CXCursor, CXClientData);

// Cursor kinds (from clang-c/Index.h)
enum : int {
    CXCursor_StructDecl = 2, CXCursor_ClassDecl = 4, CXCursor_EnumDecl = 5,
    CXCursor_FieldDecl = 6, CXCursor_EnumConstantDecl = 7,
    CXCursor_FunctionDecl = 8, CXCursor_ParmDecl = 10,
    CXCursor_CXXMethod = 21, CXCursor_Namespace = 22, CXCursor_Constructor = 24,
    CXCursor_Destructor = 25, CXCursor_CXXBaseSpecifier = 44,
    // expression kinds start at 100 (used to detect default-arg values)
    CXCursor_FirstExpr = 100,
    CXCursor_AnnotateAttr = 406,   // __attribute__((annotate("qt_signal"))) on a signal
}

// Type kinds
enum : int {
    CXType_Invalid = 0, CXType_Void = 2, CXType_Pointer = 101,
    CXType_LValueReference = 103, CXType_Record = 105, CXType_Enum = 106,
    CXType_FunctionProto = 111, CXType_ConstantArray = 112,
}

// Access specifiers
enum : int { CX_CXXInvalidAccessSpecifier = 0, CX_CXXPublic = 1 }

// --- functions -------------------------------------------------------------
CXIndex clang_createIndex(int excludeDeclarationsFromPCH, int displayDiagnostics);
CXTranslationUnit clang_parseTranslationUnit(CXIndex, const(char)* sourceFile,
    const(char*)* clangArgs, int numArgs, CXUnsavedFile* unsaved, uint numUnsaved, uint options);
CXCursor clang_getTranslationUnitCursor(CXTranslationUnit);
uint clang_visitChildren(CXCursor parent, CXCursorVisitor, CXClientData);

CXString clang_getCursorSpelling(CXCursor);
CXString clang_getCursorDisplayName(CXCursor);   // name + params, e.g. "addWidget(QWidget *, int, int)"
CXType   clang_getCursorType(CXCursor);
CXType   clang_getCursorResultType(CXCursor);
CXString clang_getTypeSpelling(CXType);
CXType   clang_getCanonicalType(CXType);
CXType   clang_getPointeeType(CXType);
CXCursor clang_getTypeDeclaration(CXType);
CXCursor clang_getCursorDefinition(CXCursor);
CXCursor clang_getCursorSemanticParent(CXCursor);
CXString clang_getCursorUSR(CXCursor);

int      clang_getCXXAccessSpecifier(CXCursor);
uint     clang_CXXMethod_isStatic(CXCursor);
uint     clang_CXXMethod_isConst(CXCursor);
uint     clang_CXXMethod_isVirtual(CXCursor);
uint     clang_CXXMethod_isPureVirtual(CXCursor);
uint     clang_CXXRecord_isAbstract(CXCursor);   // has an unoverridden pure virtual -> uninstantiable
uint     clang_CXXConstructor_isCopyConstructor(CXCursor);
uint     clang_CXXConstructor_isMoveConstructor(CXCursor);
uint     clang_isPODType(CXType);                // trivially-copyable POD -> bitwise copy safe
uint     clang_CXXMethod_isDeleted(CXCursor);    // `= delete`d special member
int      clang_Cursor_getNumArguments(CXCursor);
CXCursor clang_Cursor_getArgument(CXCursor, uint);
int      clang_Type_getNumTemplateArguments(CXType);
CXType   clang_Type_getTemplateArgumentAsType(CXType, uint);
CXType   clang_getResultType(CXType);            // return type of a function-proto type
int      clang_getNumArgTypes(CXType);           // arg count of a function-proto type
CXType   clang_getArgType(CXType, uint);         // arg i of a function-proto type
uint     clang_isCursorDefinition(CXCursor);
uint     clang_Cursor_isFunctionInlined(CXCursor);   // has an inline def -> no linkable symbol
long     clang_Type_getSizeOf(CXType);           // bytes, or negative CXTypeLayoutError
long     clang_Type_getAlignOf(CXType);
CXType   clang_getArrayElementType(CXType);      // element of a T[N] field
long     clang_getArraySize(CXType);             // N of a T[N] field
// default-argument evaluation (CXEvalResult is opaque). Kind: 1=Int, 2=Float.
alias CXEvalResult = void*;
CXEvalResult clang_Cursor_Evaluate(CXCursor);
int      clang_EvalResult_getKind(CXEvalResult);
long     clang_EvalResult_getAsLongLong(CXEvalResult);
double   clang_EvalResult_getAsDouble(CXEvalResult);
void     clang_EvalResult_dispose(CXEvalResult);
long     clang_getEnumConstantDeclValue(CXCursor);
CXType   clang_getEnumDeclIntegerType(CXCursor);
CXString clang_Cursor_getMangling(CXCursor);     // exact linker symbol (e.g. ctor)
CXSourceLocation clang_getCursorLocation(CXCursor);
CXSourceRange    clang_getCursorExtent(CXCursor);      // full source span of a cursor
CXSourceLocation clang_getRangeStart(CXSourceRange);
CXSourceLocation clang_getRangeEnd(CXSourceRange);
void     clang_getFileLocation(CXSourceLocation, CXFile*, uint*, uint*, uint*);
CXString clang_getFileName(CXFile);

const(char)* clang_getCString(CXString);
void clang_disposeString(CXString);

// --- D convenience ---------------------------------------------------------
import std.string : fromStringz;

/// CXString -> GC D string (disposes the CXString).
string str(CXString s) {
    auto c = clang_getCString(s);
    string r = c ? c.fromStringz.idup : "";
    clang_disposeString(s);
    return r;
}
