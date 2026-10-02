package android.database;

/**
 * Host tests run against android.jar's stubs, whose SQLException drops its
 * message. The bundled SQLite driver throws this class from native code, so
 * this real one (first on the test classpath) keeps SQLite's error text.
 */
public class SQLException extends RuntimeException {
    public SQLException() { super(); }
    public SQLException(String error) { super(error); }
    public SQLException(String error, Throwable cause) { super(error, cause); }
}
