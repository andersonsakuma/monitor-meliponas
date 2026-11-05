package br.org.fis.meliponas;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

/** Entrega os relatórios em PDF a outros aplicativos (WhatsApp, e-mail) sem expor outros arquivos. */
public class Arquivos extends ContentProvider {
    public static final String AUTORIDADE = "br.org.fis.meliponas.arquivos";

    private File arquivo(Uri u) throws FileNotFoundException {
        String nome = u.getLastPathSegment();
        if (nome == null || nome.contains("/") || nome.contains("..")) throw new FileNotFoundException();
        File f = new File(new File(getContext().getCacheDir(), "relatorios"), nome);
        if (!f.exists()) throw new FileNotFoundException(nome);
        return f;
    }

    @Override public boolean onCreate() { return true; }

    @Override
    public Cursor query(Uri u, String[] proj, String sel, String[] args, String ord) {
        try {
            File f = arquivo(u);
            MatrixCursor c = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            c.addRow(new Object[]{f.getName(), f.length()});
            return c;
        } catch (Exception e) { return null; }
    }

    @Override public String getType(Uri u) { return "application/pdf"; }

    @Override
    public ParcelFileDescriptor openFile(Uri u, String modo) throws FileNotFoundException {
        return ParcelFileDescriptor.open(arquivo(u), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public Uri insert(Uri u, ContentValues v) { return null; }
    @Override public int delete(Uri u, String s, String[] a) { return 0; }
    @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
}
