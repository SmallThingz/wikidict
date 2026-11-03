package app.smallthingz.dict;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.concurrent.ConcurrentHashMap;

/** Test APK only: synthetic one-byte streams, held until the test releases them. */
public final class ImportLifecycleProvider extends ContentProvider {
    private static final class Entry {
        int opens;
        boolean released;
        final ArrayList<ParcelFileDescriptor.AutoCloseOutputStream> writers = new ArrayList<>();
    }
    private final ConcurrentHashMap<String, Entry> entries = new ConcurrentHashMap<>();

    @Override public boolean onCreate() { return true; }
    private Entry entry(String token) {
        Entry value = entries.get(token);
        if (value == null) throw new IllegalArgumentException("Unknown synthetic stream");
        return value;
    }
    @Override public Bundle call(String method, String token, Bundle extras) {
        if (token == null) throw new IllegalArgumentException("Missing stream token");
        if (method.equals("prepare")) {
            if (entries.size() >= 8 || entries.putIfAbsent(token, new Entry()) != null)
                throw new IllegalStateException("Unexpected synthetic stream registration");
            return Bundle.EMPTY;
        }
        Entry value = entry(token);
        synchronized (value) {
            if (method.equals("await-open")) {
                long end = android.os.SystemClock.elapsedRealtime() + 10000;
                while (value.opens == 0) {
                    long remaining = end - android.os.SystemClock.elapsedRealtime();
                    if (remaining <= 0) throw new IllegalStateException("Import did not open synthetic stream");
                    try { value.wait(remaining); }
                    catch (InterruptedException failure) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException(failure);
                    }
                }
            } else if (method.equals("release") || method.equals("remove")) {
                value.released = true;
                for (ParcelFileDescriptor.AutoCloseOutputStream writer : value.writers) {
                    try { writer.close(); }
                    catch (IOException failure) { throw new IllegalStateException(failure); }
                }
                value.writers.clear();
                if (method.equals("remove")) entries.remove(token, value);
            } else if (!method.equals("state")) {
                throw new IllegalArgumentException("Unknown synthetic stream operation");
            }
            Bundle result = new Bundle();
            result.putInt("opens", value.opens);
            result.putInt("heldWriters", value.writers.size());
            return result;
        }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!mode.equals("r")) throw new FileNotFoundException("Read only");
        Entry value = entry(uri.getLastPathSegment());
        synchronized (value) {
            try {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
                try {
                    // One byte cannot install a dictionary; the open write end holds its next read.
                    ParcelFileDescriptor.AutoCloseOutputStream writer =
                        new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]);
                    writer.write(0);
                    if (value.released) writer.close(); else value.writers.add(writer);
                    value.opens++;
                    value.notifyAll();
                    return pipe[0];
                } catch (IOException failure) {
                    pipe[0].close(); pipe[1].close(); throw failure;
                }
            } catch (IOException failure) {
                FileNotFoundException wrapped = new FileNotFoundException("Synthetic pipe failed");
                wrapped.initCause(failure); throw wrapped;
            }
        }
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection,
                                  String[] selectionArgs, String sortOrder) {
        entry(uri.getLastPathSegment());
        MatrixCursor result = new MatrixCursor(new String[] { OpenableColumns.DISPLAY_NAME });
        result.addRow(new Object[] { "lifecycle-fixture.wikblb" });
        return result;
    }
    @Override public String getType(Uri uri) { return "application/x-wikblb"; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
