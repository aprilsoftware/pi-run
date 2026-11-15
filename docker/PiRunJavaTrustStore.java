// SPDX-License-Identifier: MIT

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.Collection;
import java.util.HexFormat;

/** Builds a Java truststore from the image defaults and the mounted host CA bundle. */
public final class PiRunJavaTrustStore {
    private PiRunJavaTrustStore() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 4) {
            throw new IllegalArgumentException(
                    "usage: PiRunJavaTrustStore DEFAULT_STORE HOST_BUNDLE OUTPUT STORE_PASSWORD");
        }

        Path defaultStore = Path.of(args[0]);
        Path hostBundle = Path.of(args[1]);
        Path output = Path.of(args[2]);
        char[] password = args[3].toCharArray();

        KeyStore trustStore = KeyStore.getInstance("JKS");
        try (InputStream input = Files.newInputStream(defaultStore)) {
            trustStore.load(input, password);
        }

        Collection<? extends Certificate> certificates;
        try (InputStream input = Files.newInputStream(hostBundle)) {
            certificates = CertificateFactory.getInstance("X.509").generateCertificates(input);
        }
        if (certificates.isEmpty()) {
            throw new IllegalArgumentException("host CA bundle contains no X.509 certificates");
        }

        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        for (Certificate certificate : certificates) {
            if (trustStore.getCertificateAlias(certificate) != null) {
                continue;
            }
            String fingerprint = HexFormat.of().formatHex(sha256.digest(certificate.getEncoded()));
            trustStore.setCertificateEntry("pi-run-host-" + fingerprint, certificate);
        }

        try (OutputStream destination = Files.newOutputStream(
                output, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            trustStore.store(destination, password);
        }
    }
}
