plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import groovy.json.JsonSlurper

val localProperties = Properties()
val localPropertiesFile = file("../local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun localProp(name: String): String {
    return localProperties.getProperty(name) ?: ""
}

fun firstLocalProp(vararg names: String): String {
    return names.firstNotNullOfOrNull { localProperties.getProperty(it)?.takeIf(String::isNotBlank) } ?: ""
}

fun keystoreProp(name: String): String {
    return keystoreProperties.getProperty(name) ?: ""
}

val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { keystoreProp(it).isNotBlank() }

val isolatedSherpaLibs = layout.buildDirectory.dir("generated/isolatedSherpa/jniLibs")
val prepareIsolatedSherpaLibs = tasks.register("prepareIsolatedSherpaLibs") {
    val packageConfig = rootProject.file("../.dart_tool/package_config.json")
    inputs.file(packageConfig)
    outputs.dir(isolatedSherpaLibs)
    outputs.upToDateWhen { false }
    doLast {
        val entries = (JsonSlurper().parse(packageConfig) as Map<*, *>)["packages"] as List<*>
        // Keep sherpa's versioned ONNX symbols separate from DUIX's 1.20.0 runtime.
        val originalName = "libonnxruntime.so".toByteArray(Charsets.US_ASCII)
        val isolatedName = "libonnxsherpa1.so".toByteArray(Charsets.US_ASCII)
        check(originalName.size == isolatedName.size)
        val architectures = mapOf(
            "arm64" to "arm64-v8a",
            "armeabi" to "armeabi-v7a",
            "x86" to "x86",
            "x86_64" to "x86_64",
        )
        for ((packageSuffix, abi) in architectures) {
            val packageName = "sherpa_onnx_android_$packageSuffix"
            val entry = entries.filterIsInstance<Map<*, *>>()
                .single { it["name"] == packageName }
            val packageRoot = File(packageConfig.parentFile.toURI().resolve(entry["rootUri"] as String))
            val sourceDir = File(packageRoot, "android/src/main/jniLibs/$abi")
            val outputDir = isolatedSherpaLibs.get().asFile.resolve(abi)
            outputDir.mkdirs()
            for (library in listOf(
                "libonnxruntime.so",
                "libsherpa-onnx-c-api.so",
                "libsherpa-onnx-cxx-api.so",
            )) {
                val bytes = File(sourceDir, library).readBytes()
                var replacements = 0
                for (offset in 0..bytes.size - originalName.size) {
                    if (bytes[offset] != originalName[0]) continue
                    if (originalName.indices.all { bytes[offset + it] == originalName[it] }) {
                        isolatedName.copyInto(bytes, offset)
                        replacements++
                    }
                }
                check(replacements > 0) { "$packageName/$library has no ONNX Runtime link" }
                val outputName = if (library == "libonnxruntime.so") "libonnxsherpa1.so" else library
                File(outputDir, outputName).writeBytes(bytes)
            }
        }
    }
}

tasks.matching {
    it.name.startsWith("merge") &&
        (it.name.endsWith("NativeLibs") || it.name.endsWith("JniLibFolders"))
}
    .configureEach { dependsOn(prepareIsolatedSherpaLibs) }

android {
    namespace = "com.namson.ai_secretary"
    compileSdk = 36

    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    sourceSets.getByName("main").jniLibs.srcDir(isolatedSherpaLibs.get().asFile)

    defaultConfig {
        applicationId = "com.namson.ai_secretary"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        manifestPlaceholders["appLabel"] = "数字人底座"

        buildConfigField("String", "DEEPSEEK_KEY", "\"${localProp("DEEPSEEK_KEY")}\"")
        buildConfigField("String", "MINIMAX_KEY", "\"${firstLocalProp("MINIMAX_KEY", "MIMO_KEY")}\"")
        buildConfigField("String", "TENCENT_SECRET_ID", "\"${localProp("TENCENT_SECRET_ID")}\"")
        buildConfigField("String", "TENCENT_SECRET_KEY", "\"${localProp("TENCENT_SECRET_KEY")}\"")
        buildConfigField("String", "BAILIAN_WORKSPACE_ID", "\"${localProp("BAILIAN_WORKSPACE_ID")}\"")
        buildConfigField("String", "BAILIAN_API_KEY", "\"${localProp("BAILIAN_API_KEY")}\"")
    }

    flavorDimensions += "edition"
    productFlavors {
        create("foundation") {
            dimension = "edition"
            applicationIdSuffix = ".foundation"
            manifestPlaceholders["appLabel"] = "数字人底座"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProp("storeFile"))
                storePassword = keystoreProp("storePassword")
                keyAlias = keystoreProp("keyAlias")
                keyPassword = keystoreProp("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":duix-sdk"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("androidx.multidex:multidex:2.0.1")
}
