package com.workplace.headset;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import org.json.JSONObject;

/** The same stream bytes as LAN, through an authenticated, certificate-pinned TLS tunnel. */
public final class InternetTransport {
    private static final class Session {
        final String host, device, token;
        final int port;
        final SSLContext tls;
        Session(String profileText, String identityText) throws Exception {
            JSONObject profile = new JSONObject(profileText), identity = new JSONObject(identityText);
            host = profile.getString("host");
            port = profile.getInt("port");
            device = identity.getString("device");
            token = identity.getString("token");
            if (host.isEmpty() || port < 1 || port > 65535 || token.length() < 32) {
                throw new IOException("invalid_internet_configuration");
            }
            X509Certificate trusted = (X509Certificate)CertificateFactory.getInstance("X.509").generateCertificate(
                new ByteArrayInputStream(profile.getString("certificate").getBytes(StandardCharsets.US_ASCII)));
            final byte[] expected = MessageDigest.getInstance("SHA-256").digest(trusted.getEncoded());
            TrustManager manager = new X509TrustManager() {
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[] {trusted}; }
                public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                    throw new CertificateException("client_certificate_not_used");
                }
                public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                    try {
                        if (chain == null || chain.length == 0) { throw new CertificateException("missing_server_identity"); }
                        chain[0].checkValidity();
                        byte[] actual = MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded());
                        if (!MessageDigest.isEqual(expected, actual)) { throw new CertificateException("server_identity_changed"); }
                    } catch (CertificateException error) { throw error; }
                    catch (Exception error) { throw new CertificateException("invalid_server_identity"); }
                }
            };
            tls = SSLContext.getInstance("TLS");
            tls.init(null, new TrustManager[] {manager}, new SecureRandom());
        }
    }
    private static volatile Session session;
    private static volatile boolean required;

    public static synchronized boolean configure(String profile, String identity, boolean enabled) {
        required = enabled;
        if (!enabled) { session = null; return true; }
        try { session = new Session(profile, identity); return true; }
        catch (Exception error) { session = null; return false; }
    }

    public static Socket connect(Socket raw, String host, int port, int timeoutMs) throws Exception {
        Session active = session;
        if (active == null) {
            if (required) { throw new IOException("internet_configuration_required"); }
            raw.connect(new InetSocketAddress(host, port), timeoutMs);
            return raw;
        }
        raw.connect(new InetSocketAddress(active.host, active.port), timeoutMs);
        SSLSocket socket = (SSLSocket)active.tls.getSocketFactory().createSocket(raw, active.host, active.port, true);
        socket.setSoTimeout(10000);
        socket.setEnabledProtocols(new String[] {"TLSv1.3", "TLSv1.2"});
        socket.startHandshake();
        JSONObject message = new JSONObject();
        message.put("v", 1); message.put("op", "tunnel"); message.put("port", port);
        message.put("device", active.device); message.put("token", active.token);
        socket.getOutputStream().write((message.toString() + "\n").getBytes(StandardCharsets.UTF_8));
        socket.getOutputStream().flush();
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        boolean ended = false;
        while (line.size() <= 4096) {
            int value = socket.getInputStream().read();
            if (value < 0) { throw new IOException("internet_gateway_closed"); }
            if (value == '\n') { ended = true; break; }
            line.write(value);
        }
        if (!ended || !new JSONObject(line.toString("UTF-8")).optBoolean("ok", false)) {
            throw new IOException("internet_channel_rejected");
        }
        socket.setSoTimeout(0);
        return socket;
    }
}
