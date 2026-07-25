// metaobj.d — D bindings for the native meta-object machinery (qtd_meta.cpp).
module metaobj;

alias QtdSlotFn      = extern (C) void function(void* dself, int id, void** args) nothrow;
alias QtdRWFn        = extern (C) void function(void* dself, int id, void* arg) nothrow;
alias QtdDtorFn      = extern (C) void function(void* dself) nothrow;

extern (C) nothrow @nogc {
    void* qtd_mob_new(const(char)* className);
    int   qtd_mob_add_signal(void* b, const(char)* sig);
    int   qtd_mob_add_slot(void* b, const(char)* sig);
    int   qtd_mob_add_property(void* b, const(char)* name, const(char)* type, int notifyIdx);
    void* qtd_mob_create_object(void* b, void* dself, QtdSlotFn s, QtdRWFn r, QtdRWFn w,
                                QtdDtorFn d);
    void  qtd_object_delete(void* obj);
    void  qtd_object_emit(void* obj, int localSignalIndex, void** args);
    void  qtd_object_emit_queued(void* obj, int localSignalIndex);
    // BindingManager C support (destroyed hook, ownership, plain-QObject helpers)
    // now lives in bindingmanager.d / qtd_binding.cpp.

    void  qtd_ctx_set_object(void* engine, const(char)* name, void* obj);
    int   qtd_obj_read_int(void* obj, const(char)* prop);
    void  qtd_obj_invoke(void* obj, const(char)* method);
}
