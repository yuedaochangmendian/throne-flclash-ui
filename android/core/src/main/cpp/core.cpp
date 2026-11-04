// The JNI shim for the self-owned kernel bridge (bettbox android/core shape).
//
// JNI_OnLoad fills throne_callbacks_t with thunks that reach Kotlin: the tun
// token handed to throne_start_tun is a TunInterface global ref (protect /
// resolverProcess); everything else goes to the CorePlatform registered through
// Core.setPlatform. The Kotlin->Go direction (startTun, interface-monitor
// reports) calls the throne_* C ABI exported by the Go shared library directly.

#ifdef LIBCORE
#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdlib>
#include "jni_helper.h"
#include "bridge_symbols.h"

static jobject g_platform;   // CorePlatform global ref
static jmethodID m_platform[16];
static jmethodID m_tun_protect;
static jmethodID m_tun_resolver;
static jmethodID m_func_invoke;

enum {
    P_OPEN_TUN = 0,
    P_USE_AUTO_DETECT,
    P_USE_PROC_FS,
    P_FIND_OWNER,
    P_PACKAGE_NAMES,
    P_START_MONITOR,
    P_CLOSE_MONITOR,
    P_GET_INTERFACES,
    P_READ_WIFI,
    P_CLEAR_DNS,
    P_SEND_NOTIFICATION,
    P_CANCEL_NOTIFICATION,
    P_DNS_RAW,
    P_DNS_LOOKUP,
    P_DNS_EXCHANGE,
};

// --- tun-scoped thunks (the TunInterface token) -----------------------------

static void cb_protect(void *tun, int32_t fd) {
    if (tun == nullptr) return;
    ATTACH_JNI();
    env->CallVoidMethod(static_cast<jobject>(tun), m_tun_protect, fd);
    jni_catch_exception(env);
}

static const char *cb_resolver_process(void *tun, int32_t protocol,
                                       const char *source, const char *target,
                                       int32_t uid) {
    if (tun == nullptr) return strdup("");
    ATTACH_JNI();
    if (env->PushLocalFrame(8) < 0) return strdup("");
    const auto src_str = new_string(source != nullptr ? source : "");
    const auto dst_str = new_string(target != nullptr ? target : "");
    const auto result = reinterpret_cast<jstring>(env->CallObjectMethod(
        static_cast<jobject>(tun), m_tun_resolver, protocol, src_str, dst_str, uid));
    jni_catch_exception(env);
    const auto out = get_string(result);
    env->PopLocalFrame(nullptr);
    return out;
}

// protect() is also what autoDetectInterfaceControl means on Android.
static const char *cb_auto_detect(void *tun, int32_t fd) {
    cb_protect(tun, fd);
    return strdup("");
}

static void cb_release_object(void *obj) {
    if (obj == nullptr) return;
    ATTACH_JNI();
    del_global(static_cast<jobject>(obj));
}

// --- platform-wide thunks (the CorePlatform singleton) ----------------------

// open_tun: the kernel needs the VPN established mid-start. Kotlin builds
// VpnService.Builder from the TunOptions handle (throne_TunOptions_toJSON),
// establishes, feeds the fd through throne_start_tun and answers the fd here.
static int32_t cb_open_tun(int64_t options) {
    if (g_platform == nullptr) return -1;
    ATTACH_JNI();
    const auto r = env->CallIntMethod(g_platform, m_platform[P_OPEN_TUN], static_cast<jlong>(options));
    jni_catch_exception(env);
    return r;
}

static int8_t cb_bool(jmethodID method) {
    if (g_platform == nullptr) return 0;
    ATTACH_JNI();
    const auto r = env->CallBooleanMethod(g_platform, method);
    jni_catch_exception(env);
    return r ? 1 : 0;
}

static const char *cb_string_call(jmethodID method, const char *sig,
                                  const jvalue *args) {
    if (g_platform == nullptr) return strdup("");
    ATTACH_JNI();
    const auto result = reinterpret_cast<jstring>(
        env->CallObjectMethodA(g_platform, method, args));
    jni_catch_exception(env);
    const auto out = get_string(result);
    return out;
}

static int8_t cb_use_auto_detect(void *tun) { return cb_bool(m_platform[P_USE_AUTO_DETECT]); }
static int8_t cb_use_proc_fs(void *tun) { return cb_bool(m_platform[P_USE_PROC_FS]); }

static const char *cb_find_owner(void *tun, int32_t ip_protocol,
                                 const char *source_address, int32_t source_port,
                                 const char *destination_address, int32_t destination_port) {
    ATTACH_JNI();
    if (env->PushLocalFrame(8) < 0) return strdup("");
    jvalue args[5];
    args[0].i = ip_protocol;
    args[1].l = new_string(source_address != nullptr ? source_address : "");
    args[2].i = source_port;
    args[3].l = new_string(destination_address != nullptr ? destination_address : "");
    args[4].i = destination_port;
    const auto out = cb_string_call(m_platform[P_FIND_OWNER], "", args);
    env->PopLocalFrame(nullptr);
    return out;
}

static const char *cb_package_names(void *tun, int32_t uid) {
    jvalue args[1];
    args[0].i = uid;
    return cb_string_call(m_platform[P_PACKAGE_NAMES], "", args);
}

static const char *cb_start_monitor(void *tun, int64_t listener) {
    jvalue args[1];
    args[0].j = listener;
    return cb_string_call(m_platform[P_START_MONITOR], "", args);
}

static const char *cb_close_monitor(void *tun, int64_t listener) {
    jvalue args[1];
    args[0].j = listener;
    return cb_string_call(m_platform[P_CLOSE_MONITOR], "", args);
}

static const char *cb_get_interfaces(void *tun) {
    return cb_string_call(m_platform[P_GET_INTERFACES], "", nullptr);
}

static const char *cb_read_wifi(void *tun) {
    return cb_string_call(m_platform[P_READ_WIFI], "", nullptr);
}

static void cb_clear_dns(void *tun) {
    if (g_platform == nullptr) return;
    ATTACH_JNI();
    env->CallVoidMethod(g_platform, m_platform[P_CLEAR_DNS]);
    jni_catch_exception(env);
}

static const char *cb_send_notification(void *tun, const char *notification_json) {
    ATTACH_JNI();
    if (env->PushLocalFrame(4) < 0) return strdup("");
    jvalue args[1];
    args[0].l = new_string(notification_json != nullptr ? notification_json : "{}");
    const auto out = cb_string_call(m_platform[P_SEND_NOTIFICATION], "", args);
    env->PopLocalFrame(nullptr);
    return out;
}

static const char *cb_cancel_notification(void *tun, const char *identifier, int32_t type_id) {
    ATTACH_JNI();
    if (env->PushLocalFrame(4) < 0) return strdup("");
    jvalue args[2];
    args[0].l = new_string(identifier != nullptr ? identifier : "");
    args[1].i = type_id;
    const auto out = cb_string_call(m_platform[P_CANCEL_NOTIFICATION], "", args);
    env->PopLocalFrame(nullptr);
    return out;
}

static int8_t cb_dns_raw(void *tun) { return cb_bool(m_platform[P_DNS_RAW]); }

static const char *cb_dns_lookup(void *tun, int64_t ctx, const char *network,
                                 const char *domain) {
    ATTACH_JNI();
    if (env->PushLocalFrame(6) < 0) return strdup("");
    jvalue args[3];
    args[0].j = ctx;
    args[1].l = new_string(network != nullptr ? network : "");
    args[2].l = new_string(domain != nullptr ? domain : "");
    const auto out = cb_string_call(m_platform[P_DNS_LOOKUP], "", args);
    env->PopLocalFrame(nullptr);
    return out;
}

static const char *cb_dns_exchange(void *tun, int64_t ctx, const uint8_t *message,
                                   int32_t message_len) {
    if (g_platform == nullptr) return strdup("");
    ATTACH_JNI();
    if (env->PushLocalFrame(8) < 0) return strdup("");
    const auto array = env->NewByteArray(message_len);
    if (array != nullptr && message_len > 0) {
        env->SetByteArrayRegion(array, 0, message_len, reinterpret_cast<const jbyte *>(message));
    }
    jvalue args[2];
    args[0].j = ctx;
    args[1].l = array;
    const auto result = reinterpret_cast<jstring>(env->CallObjectMethodA(
        g_platform, m_platform[P_DNS_EXCHANGE], args));
    jni_catch_exception(env);
    const auto out = get_string(result);
    env->PopLocalFrame(nullptr);
    return out;
}

static void cb_func_invoke(void *obj) {
    if (obj == nullptr) return;
    ATTACH_JNI();
    env->CallVoidMethod(static_cast<jobject>(obj), m_func_invoke);
    jni_catch_exception(env);
}

// --- Kotlin -> Go ------------------------------------------------------------

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_startTun(JNIEnv *env, jobject, const jint fd, jobject tun) {
    const auto token = new_global(tun);
    throne_start_tun(fd, token);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_stopTun(JNIEnv *) {
    throne_stop_tun();
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_suspend(JNIEnv *, jobject, jint suspended) {
    throne_suspend(suspended);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_setPlatform(JNIEnv *env, jobject, jobject platform) {
    if (g_platform != nullptr) {
        del_global(g_platform);
    }
    g_platform = new_global(platform);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_updateDefaultInterface(JNIEnv *env, jobject,
                                                     const jlong listener,
                                                     jstring name, const jint index,
                                                     const jboolean is_expensive,
                                                     const jboolean is_constrained) {
    scoped_string n = get_string(name);
    throne_InterfaceUpdateListener_updateDefaultInterface(
        listener, n, index, is_expensive ? 1 : 0, is_constrained ? 1 : 0);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_updateNetworkPath(JNIEnv *env, jobject,
                                                const jlong listener, jstring path) {
    scoped_string p = get_string(path);
    throne_InterfaceUpdateListener_updateNetworkPath(listener, p);
}

extern "C"
JNIEXPORT jstring JNICALL
Java_io_throne_bbox_core_Core_tunSpecJson(JNIEnv *env, jobject, const jlong handle) {
    const auto json = throne_TunOptions_toJSON(handle);
    const char *text = json != nullptr ? json : "";
    if (text[0] == '\0') {
        // An empty spec used to surface only as a JSONException in VpnService,
        // which hid whether the handle was unknown or the marshaling panicked.
        const auto last = throne_last_error();
        __android_log_print(ANDROID_LOG_WARN, "ThroneTun",
                            "tunSpecJson(handle=%lld) is empty; last_error=%s",
                            static_cast<long long>(handle),
                            last != nullptr ? last : "(none)");
        if (last != nullptr) throne_free(const_cast<char *>(last));
    }
    const auto out = env->NewStringUTF(text);
    if (json != nullptr) throne_free(const_cast<char *>(json));
    return out;
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_exchangeSuccess(JNIEnv *env, jobject, const jlong handle, jstring result) {
    scoped_string r = get_string(result);
    throne_ExchangeContext_success(handle, r);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_exchangeRawSuccess(JNIEnv *env, jobject, const jlong handle, jbyteArray result) {
    const jsize len = result != nullptr ? env->GetArrayLength(result) : 0;
    jbyte *bytes = len > 0 ? env->GetByteArrayElements(result, nullptr) : nullptr;
    throne_ExchangeContext_rawSuccess(handle, reinterpret_cast<uint8_t *>(bytes), len);
    if (bytes != nullptr) env->ReleaseByteArrayElements(result, bytes, JNI_ABORT);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_exchangeErrorCode(JNIEnv *, jobject, const jlong handle, const jint code) {
    throne_ExchangeContext_errorCode(handle, code);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_exchangeErrnoCode(JNIEnv *, jobject, const jlong handle, const jint code) {
    throne_ExchangeContext_errnoCode(handle, code);
}

extern "C"
JNIEXPORT void JNICALL
Java_io_throne_bbox_core_Core_exchangeOnCancel(JNIEnv *env, jobject, const jlong handle, jobject callback) {
    throne_ExchangeContext_onCancel(handle, callback != nullptr ? new_global(callback) : nullptr);
}

// --- registration ------------------------------------------------------------

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    initialize_jni(vm, env);

    const auto c_tun = find_class("io/throne/bbox/core/TunInterface");
    m_tun_protect = find_method(c_tun, "protect", "(I)V");
    m_tun_resolver = find_method(c_tun, "resolverProcess",
                                 "(ILjava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");

    const auto c_platform = find_class("io/throne/bbox/core/CorePlatform");
    m_platform[P_OPEN_TUN] = find_method(c_platform, "openTun", "(J)I");
    m_platform[P_USE_AUTO_DETECT] = find_method(c_platform, "usePlatformAutoDetectInterfaceControl", "()Z");
    m_platform[P_USE_PROC_FS] = find_method(c_platform, "useProcFS", "()Z");
    m_platform[P_FIND_OWNER] = find_method(c_platform, "findConnectionOwner",
                                           "(ILjava/lang/String;ILjava/lang/String;I)Ljava/lang/String;");
    m_platform[P_PACKAGE_NAMES] = find_method(c_platform, "packageNamesByUid", "(I)Ljava/lang/String;");
    m_platform[P_START_MONITOR] = find_method(c_platform, "startDefaultInterfaceMonitor", "(J)Ljava/lang/String;");
    m_platform[P_CLOSE_MONITOR] = find_method(c_platform, "closeDefaultInterfaceMonitor", "(J)Ljava/lang/String;");
    m_platform[P_GET_INTERFACES] = find_method(c_platform, "getInterfaces", "()Ljava/lang/String;");
    m_platform[P_READ_WIFI] = find_method(c_platform, "readWifiState", "()Ljava/lang/String;");
    m_platform[P_CLEAR_DNS] = find_method(c_platform, "clearDnsCache", "()V");
    m_platform[P_SEND_NOTIFICATION] = find_method(c_platform, "sendNotification", "(Ljava/lang/String;)Ljava/lang/String;");
    m_platform[P_CANCEL_NOTIFICATION] = find_method(c_platform, "cancelNotification", "(Ljava/lang/String;I)Ljava/lang/String;");
    m_platform[P_DNS_RAW] = find_method(c_platform, "localDnsRaw", "()Z");
    m_platform[P_DNS_LOOKUP] = find_method(c_platform, "localDnsLookup", "(JLjava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    m_platform[P_DNS_EXCHANGE] = find_method(c_platform, "localDnsExchange", "(J[B)Ljava/lang/String;");

    const auto c_func = find_class("io/throneproj/mobile/Func");
    m_func_invoke = find_method(c_func, "invoke", "()V");

    throne_callbacks_t table{};
    table.open_tun = cb_open_tun;
    table.protect = cb_protect;
    table.resolver_process = cb_resolver_process;
    table.release_object = cb_release_object;
    table.use_platform_auto_detect_interface_control = cb_use_auto_detect;
    table.auto_detect_interface_control = cb_auto_detect;
    table.use_proc_fs = cb_use_proc_fs;
    table.find_connection_owner = cb_find_owner;
    table.package_names_by_uid = cb_package_names;
    table.start_default_interface_monitor = cb_start_monitor;
    table.close_default_interface_monitor = cb_close_monitor;
    table.get_interfaces = cb_get_interfaces;
    table.read_wifi_state = cb_read_wifi;
    table.clear_dns_cache = cb_clear_dns;
    table.send_notification = cb_send_notification;
    table.cancel_notification = cb_cancel_notification;
    table.local_dns_raw = cb_dns_raw;
    table.local_dns_lookup = cb_dns_lookup;
    table.local_dns_exchange = cb_dns_exchange;
    table.func_invoke = cb_func_invoke;
    throne_register_callbacks(&table);
    return JNI_VERSION_1_6;
}
#endif
