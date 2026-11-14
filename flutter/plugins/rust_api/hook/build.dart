import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
//
// On Windows the NDK ships no libclang shared library at all — pip libclang
// provides the .dll but reports clang 18, while the NDK's headers live under
// lib/clang/19/include. bindgen therefore cannot find stdbool.h, stddef.h, etc.
// The fix is to add the NDK's own clang include directory explicitly, alongside
// the Android sysroot headers.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;

  // Find libclang: on Linux/macOS it's under lib/ or lib64/ inside the NDK;
  // on Windows it's absent and pip libclang provides it via LIBCLANG_PATH.
  String? libclangPath;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      libclangPath = directory.path;
      break;
    }
  }
  // Windows fallback: pip libclang wheel.
  if (libclangPath == null) {
    final env = Platform.environment['LIBCLANG_PATH'];
    if (env != null && env.isNotEmpty) {
      libclangPath = env;
    }
  }
  if (libclangPath == null) {
    throw StateError(
      'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
      'passed cannot run bindgen for rquickjs',
    );
  }

  final result = <String, String>{'LIBCLANG_PATH': libclangPath};

  // The pip libclang .dll reports clang 18, but the NDK's compiler headers
  // live under lib/clang/19/include. Without an explicit -isystem the clang
  // frontend searches lib/clang/18/include (which does not exist) and
  // every C standard header goes missing.
  //
  // native_toolchain_rust sets BINDGEN_EXTRA_CLANG_ARGS_<target> itself with
  // --sysroot and -I using Windows backslash paths — clang's path resolver on
  // Windows rejects those when loaded through pip libclang (it strips the
  // separators). We override the per-target var with -isystem and forward-slash
  // paths, which is the only form that works.
  final sysroot = File.fromUri(compiler).parent.parent;
  final clangInclude = Directory('${llvmRoot.path}/lib/clang');
  String? clangVerInclude;
  if (clangInclude.existsSync()) {
    for (final entry in clangInclude.listSync()) {
      final candidate = Directory('${entry.path}/include');
      if (candidate.existsSync() &&
          File('${candidate.path}/stdbool.h').existsSync()) {
        clangVerInclude = candidate.path.replaceAll('\\', '/');
        break;
      }
    }
  }

  // Build per-target env vars for every Android ABI rquickjs might bindgen for.
  final sysrootFwd = sysroot.path.replaceAll('\\', '/');
  for (final abi in const [
    'armv7-linux-androideabi',
    'aarch64-linux-android',
    'x86_64-linux-android',
    'i686-linux-android',
  ]) {
    final archInclude = switch (abi) {
      'armv7-linux-androideabi' => 'arm-linux-androideabi',
      'aarch64-linux-android' => 'aarch64-linux-android',
      'x86_64-linux-android' => 'x86_64-linux-android',
      'i686-linux-android' => 'i686-linux-android',
      _ => abi,
    };
    final args = <String>[
      '-isystem $sysrootFwd/sysroot/usr/include/$archInclude',
      '-isystem $sysrootFwd/sysroot/usr/include',
    ];
    if (clangVerInclude != null) {
      args.add('-isystem $clangVerInclude');
    }
    // MinGW's gcc include tree as a last-resort fallback for host C headers.
    const mingwRoot = 'E:/hu/toolchain/mingw64/mingw64';
    final mingwGccInclude =
        Directory('$mingwRoot/lib/gcc/x86_64-w64-mingw32/16.2.0/include');
    if (mingwGccInclude.existsSync()) {
      args.add('-isystem ${mingwGccInclude.path.replaceAll("\\", "/")}');
    }
    final envKey =
        'BINDGEN_EXTRA_CLANG_ARGS_${abi.replaceAll('-', '_')}';
    result[envKey] = args.join(' ');
  }

  return result;
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
