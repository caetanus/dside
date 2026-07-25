/* qml_shim.h — C ABI contract for the QtQml/QJS D binding.
 *
 * Hand-written for the bootstrap "hello world". This is EXACTLY the shape the
 * libclang generator will emit per-class in phase 1: an opaque handle per Qt
 * class + flat `extern "C"` functions. Pure C ABI => stable, portable, works
 * with any D compiler (and any other language's FFI later).
 */
#ifndef QTD_QML_SHIM_H
#define QTD_QML_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void *QtdApp;       /* QGuiApplication*        */
typedef void *QtdQmlEngine; /* QQmlApplicationEngine*  */

/* QGuiApplication ------------------------------------------------------- */
QtdApp qtd_app_new(int *argc, char **argv);
void   qtd_app_delete(QtdApp app);
int    qtd_app_exec(QtdApp app);

/* QQmlApplicationEngine ------------------------------------------------- */
QtdQmlEngine qtd_qmlengine_new(void);
void         qtd_qmlengine_delete(QtdQmlEngine engine);
void         qtd_qmlengine_load_data(QtdQmlEngine engine, const char *qml,
                                     const char *base_url);
int          qtd_qmlengine_root_count(QtdQmlEngine engine);

#ifdef __cplusplus
}
#endif

#endif /* QTD_QML_SHIM_H */
