import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}

fun signingValue(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)
        ?.trim()
        ?.takeIf(String::isNotEmpty)
        ?: keystoreProperties
            .getProperty(propertyName)
            ?.trim()
            ?.takeIf(String::isNotEmpty)

val releaseKeystorePath = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseKeystorePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
val releaseSigningAvailable = listOf(
    releaseKeystorePath,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val releaseSigningRequired =
    System.getenv("INTMUSIC_REQUIRE_RELEASE_SIGNING")?.equals("true", ignoreCase = true) == true

if (releaseSigningRequired && !releaseSigningAvailable) {
    throw GradleException(
        "IntMusic release signing is required, but the Android keystore configuration is incomplete.",
    )
}

android {
    namespace = "dev.intmusic.intmusic_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.intmusic.intmusic_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningAvailable) {
            create("release") {
                storeFile = rootProject.file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Local development can still build without secret material. Official
            // CI builds set INTMUSIC_REQUIRE_RELEASE_SIGNING=true and may never
            // fall back to an ephemeral debug certificate.
            signingConfig = if (releaseSigningAvailable) {
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
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.media:media:1.7.1")
}
