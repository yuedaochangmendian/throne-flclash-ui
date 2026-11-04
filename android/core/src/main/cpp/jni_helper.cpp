#include "jni_helper.h"

#include <cstdlib>
#include <malloc.h>
#include <cstring>

static JavaVM *global_vm;

static jclass c_string;
static jmethodID m_new_string;
static jmethodID m_get_bytes;

void initialize_jni(JavaVM *vm, JNIEnv *env) {
    global_vm = vm;

    c_string = reinterpret_cast<jclass>(new_global(find_class("java/lang/String")));
    m_new_string = find_method(c_string, "<init>", "([B)V");
    m_get_bytes = find_method(c_string, "getBytes", "()[B");
}

JavaVM *global_java_vm() {
    return global_vm;
}

char *jni_get_string(JNIEnv *env, jstring str) {
    if (str == nullptr) {
        return strdup("");
    }
    const auto array = reinterpret_cast<jbyteArray>(env->CallObjectMethod(str, m_get_bytes));
    if (array == nullptr) {
        return strdup("");
    }
    const int length = env->GetArrayLength(array);
    const auto content = static_cast<char *>(malloc(length + 1));
    if (content == nullptr) {
        return strdup("");
    }
    env->GetByteArrayRegion(array, 0, length, reinterpret_cast<jbyte *>(content));
    content[length] = 0;
    return content;
}

jstring jni_new_string(JNIEnv *env, const char *str) {
    if (str == nullptr) {
        return env->NewStringUTF("");
    }
    const auto length = static_cast<int>(strlen(str));
    const auto array = env->NewByteArray(length);
    if (array == nullptr) {
        return env->NewStringUTF("");
    }
    env->SetByteArrayRegion(array, 0, length, reinterpret_cast<const jbyte *>(str));
    return reinterpret_cast<jstring>(env->NewObject(c_string, m_new_string, array));
}

int jni_catch_exception(JNIEnv *env) {
    const int result = env->ExceptionCheck();
    if (result) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
    return result;
}

void jni_attach_thread(scoped_jni *jni) {
    jint result = global_vm->GetEnv(reinterpret_cast<void **>(&jni->env), JNI_VERSION_1_6);
    if (result == JNI_EDETACHED) {
#ifdef __ANDROID__
        result = global_vm->AttachCurrentThread(&jni->env, nullptr);
#else
        result = global_vm->AttachCurrentThread(reinterpret_cast<void **>(&jni->env), nullptr);
#endif
        jni->require_release = result == JNI_OK;
    } else {
        jni->require_release = 0;
    }
}

void jni_detach_thread(const scoped_jni *jni) {
    if (jni->require_release) {
        global_vm->DetachCurrentThread();
    }
}

void release_string(char **str) {
    if (str != nullptr && *str != nullptr) {
        free(*str);
        *str = nullptr;
    }
}
