import jenkins.model.Jenkins
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions

// JCasC creates the node before init.groovy.d scripts execute. Share its secret
// with the inbound-agent container without publishing it in logs or Compose.
def computer = Jenkins.get().getComputer('devloom-agent')
if (computer == null) {
    throw new IllegalStateException('JCasC did not create devloom-agent')
}
def secret = Path.of('/run/devloom-agent/secret')
Files.writeString(secret, computer.getJnlpMac())
Files.setPosixFilePermissions(secret, PosixFilePermissions.fromString('rw-------'))
