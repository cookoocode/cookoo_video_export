group = "com.cookoo.cookoo_video_export"
version = "0.1.0"
plugins { id("com.android.library") }
android {
    namespace = "com.cookoo.cookoo_video_export"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies { implementation("androidx.media3:media3-transformer:1.8.0") }

kotlin {
    compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 }
}
