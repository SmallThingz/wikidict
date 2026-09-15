package app.smallthingz.dict;

import android.annotation.SuppressLint;
import android.app.ActionBar;
import android.app.Activity;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.view.Menu;
import android.view.View;
import android.view.MenuItem;
import android.webkit.CookieManager;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import android.window.OnBackInvokedDispatcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

public final class MainActivity extends Activity {
    private static final int OPEN_EXPORT = 41;
    private static final int MENU_OPEN = 1;
    private static final int MENU_CLOSE = 2;
    private static final int MAX_EXPORT_BYTES = 64 * 1024 * 1024;
    private static final String PREFS = "dict-renderer";
    private static final String PREF_URI = "last-uri";
    private static final String STATE_URI = "current-uri";
    private static final String BASE_URL = "https://dict.invalid/";

    private WebView webView;
    private Uri currentUri;
    private String shell;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        shell = readAsset("index.html");
        webView = new WebView(this);
        configureWebView();
        setContentView(webView);
        showLanding();
        if (Build.VERSION.SDK_INT >= 33) Api33Back.register(this);

        Uri restored = state == null ? null : parseUri(state.getString(STATE_URI));
        if (restored != null) {
            openUri(restored, false);
        } else if (!openIntent(getIntent())) {
            Uri previous = parseUri(getSharedPreferences(PREFS, MODE_PRIVATE).getString(PREF_URI, null));
            if (previous != null) openUri(previous, false);
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private void configureWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setBlockNetworkLoads(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        settings.setMediaPlaybackRequiresUserGesture(true);
        settings.setGeolocationEnabled(false);
        settings.setSafeBrowsingEnabled(true);
        webView.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        CookieManager.getInstance().setAcceptCookie(false);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false);
        webView.removeJavascriptInterface("searchBoxJavaBridge_");
        webView.removeJavascriptInterface("accessibility");
        webView.removeJavascriptInterface("accessibilityTraversal");
        WebView.setWebContentsDebuggingEnabled(
                (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0);
        webView.setWebViewClient(new SafeClient());
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public void onReceivedTitle(WebView view, String title) {
                if (currentUri != null && title != null && !title.trim().isEmpty()) setTitle(title);
            }
            @Override public void onPermissionRequest(PermissionRequest request) {
                request.deny();
            }
            @Override public void onGeolocationPermissionsShowPrompt(
                    String origin, GeolocationPermissions.Callback callback) {
                callback.invoke(origin, false, false);
            }
        });
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(Menu.NONE, MENU_OPEN, Menu.NONE, R.string.open_export)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM | MenuItem.SHOW_AS_ACTION_WITH_TEXT);
        menu.add(Menu.NONE, MENU_CLOSE, Menu.NONE, R.string.close_export);
        return true;
    }

    @Override
    public boolean onPrepareOptionsMenu(Menu menu) {
        MenuItem close = menu.findItem(MENU_CLOSE);
        if (close != null) close.setVisible(currentUri != null);
        return super.onPrepareOptionsMenu(menu);
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        if (item.getItemId() == MENU_OPEN) {
            chooseExport();
            return true;
        }
        if (item.getItemId() == MENU_CLOSE) {
            forgetCurrent();
            showLanding();
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    private void chooseExport() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
                .putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
                        "text/html", "application/xhtml+xml", "application/json", "text/plain"
                });
        startActivityForResult(intent, OPEN_EXPORT);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != OPEN_EXPORT || resultCode != RESULT_OK || data == null) return;
        Uri uri = data.getData();
        if (uri == null) return;
        int grants = data.getFlags();
        if ((grants & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0
                && (grants & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0) {
            try {
                getContentResolver().takePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } catch (SecurityException ignored) {
                // Some providers advertise persistence but only honor the transient grant.
            }
        }
        openUri(uri, true);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        openIntent(intent);
    }

    @SuppressWarnings("deprecation")
    private boolean openIntent(Intent intent) {
        if (intent == null) return false;
        Uri uri = null;
        if (Intent.ACTION_VIEW.equals(intent.getAction())) {
            uri = intent.getData();
        } else if (Intent.ACTION_SEND.equals(intent.getAction())) {
            Object stream = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (stream instanceof Uri) uri = (Uri) stream;
            if (uri == null) {
                ClipData clip = intent.getClipData();
                if (clip != null && clip.getItemCount() != 0) uri = clip.getItemAt(0).getUri();
            }
            if (uri == null) {
                CharSequence text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
                if (text != null) {
                    openText("Shared export", text.toString());
                    return true;
                }
            }
        }
        if (uri == null) return false;
        openUri(uri, true);
        return true;
    }

    private void openUri(Uri uri, boolean persist) {
        try {
            String text = decodeUtf8(readUri(uri));
            String html = ExportDocument.render(text, shell);
            loadDocument(html, displayName(uri));
            currentUri = uri;
            if (persist) getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putString(PREF_URI, uri.toString()).apply();
            invalidateOptionsMenu();
        } catch (IOException | ExportDocument.FormatException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void openText(String label, String text) {
        try {
            loadDocument(ExportDocument.render(text, shell), label);
            currentUri = null;
            invalidateOptionsMenu();
        } catch (ExportDocument.FormatException e) {
            Toast.makeText(this, e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void loadDocument(String html, String fallbackTitle) {
        setTitle(fallbackTitle == null || fallbackTitle.trim().isEmpty() ? "Dict" : fallbackTitle);
        ActionBar bar = getActionBar();
        if (bar != null) bar.setSubtitle("Offline export renderer");
        webView.loadDataWithBaseURL(BASE_URL, html, "text/html", "UTF-8", null);
    }

    private void showLanding() {
        currentUri = null;
        setTitle("Dict");
        ActionBar bar = getActionBar();
        if (bar != null) bar.setSubtitle("Offline export renderer");
        String landing = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'>"
                + "<meta name='color-scheme' content='light dark'><style>"
                + "html{font:16px system-ui;color-scheme:light dark}body{margin:0;min-height:80vh;display:grid;place-items:center;background:#fbfbfa;color:#1d1d1f}"
                + "main{max-width:34rem;padding:2rem}h1{font-size:3rem;margin:0 0 .5rem;color:#315efb}p{line-height:1.6;color:#666}"
                + "@media(prefers-color-scheme:dark){body{background:#111214;color:#f4f4f5}p{color:#aaa}h1{color:#7aa7ff}}"
                + "</style><main><h1>dict.</h1><p>Open a self-contained Dict HTML export or <code>dict.results.v1</code> JSON file from the Open action above.</p>"
                + "<p>The renderer stays local. This app has no network or broad storage permission.</p></main>";
        webView.loadDataWithBaseURL(BASE_URL, landing, "text/html", "UTF-8", null);
        invalidateOptionsMenu();
    }

    private void forgetCurrent() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(PREF_URI).apply();
        currentUri = null;
    }

    private byte[] readUri(Uri uri) throws IOException {
        ContentResolver resolver = getContentResolver();
        try (InputStream input = resolver.openInputStream(uri)) {
            if (input == null) throw new IOException("The selected file could not be opened.");
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[32 * 1024];
            int total = 0;
            for (int n; (n = input.read(buffer)) != -1;) {
                total += n;
                if (total > MAX_EXPORT_BYTES) throw new IOException("Export is larger than 64 MiB.");
                output.write(buffer, 0, n);
            }
            return output.toByteArray();
        }
    }

    private static String decodeUtf8(byte[] bytes) throws IOException {
        try {
            CharBuffer chars = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes));
            return chars.toString();
        } catch (CharacterCodingException e) {
            throw new IOException("Dict exports must be UTF-8 text.");
        }
    }

    private String readAsset(String name) {
        try (InputStream input = getAssets().open(name)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[16 * 1024];
            for (int n; (n = input.read(buffer)) != -1;) output.write(buffer, 0, n);
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("Bundled renderer asset is missing.", e);
        }
    }

    private String displayName(Uri uri) {
        if ("content".equals(uri.getScheme())) {
            try (Cursor cursor = getContentResolver().query(uri,
                    new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) {
                    String name = cursor.getString(0);
                    if (name != null && !name.trim().isEmpty()) return name;
                }
            } catch (RuntimeException ignored) {}
        }
        return uri.getLastPathSegment();
    }

    private static Uri parseUri(String raw) {
        if (raw == null || raw.trim().isEmpty()) return null;
        try { return Uri.parse(raw); } catch (RuntimeException ignored) { return null; }
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (currentUri != null) out.putString(STATE_URI, currentUri.toString());
    }

    private void handleBack() {
        if (webView.canGoBack()) {
            webView.goBack();
        } else if (currentUri != null) {
            forgetCurrent();
            showLanding();
        } else {
            finishAfterTransition();
        }
    }

    @SuppressLint("GestureBackNavigation")
    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        // Android 13+ uses Api33Back; this override is only the API 28-32 fallback.
        if (Build.VERSION.SDK_INT < 33) handleBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.stopLoading();
            webView.loadUrl("about:blank");
            webView.clearHistory();
            webView.removeAllViews();
            webView.destroy();
        }
        super.onDestroy();
    }

    @SuppressLint("NewApi")
    private static final class Api33Back {
        static void register(MainActivity activity) {
            activity.getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT, activity::handleBack);
        }
    }

    private final class SafeClient extends WebViewClient {
        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            if (!request.isForMainFrame()) return false;
            Uri uri = request.getUrl();
            String scheme = uri.getScheme();
            if ("https".equals(scheme) && "dict.invalid".equals(uri.getHost())) return false;
            if ("http".equals(scheme) || "https".equals(scheme)) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri));
                } catch (RuntimeException e) {
                    Toast.makeText(MainActivity.this, "No browser can open this link.", Toast.LENGTH_SHORT).show();
                }
                return true;
            }
            return !"about".equals(scheme) && !"data".equals(scheme);
        }
    }
}
