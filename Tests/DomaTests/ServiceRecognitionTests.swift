@testable import Doma
import XCTest

final class ServiceRecognitionTests: XCTestCase {
    func testRecognizesDeveloperRuntimesZrokMinikubeAndSystemServices() throws {
        let output = """
        __USER__
        518636
        __SS__
        LISTEN 0 128 127.0.0.1:4173 0.0.0.0:* users:(("node",pid=101,fd=3)) uid:518636 ino:1
        LISTEN 0 128 127.0.0.1:4180 0.0.0.0:* users:(("node",pid=102,fd=3)) uid:518636 ino:2
        LISTEN 0 128 127.0.0.1:7000 0.0.0.0:* users:(("ruby",pid=103,fd=3)) uid:518636 ino:3
        LISTEN 0 128 127.0.0.1:8765 0.0.0.0:* users:(("python3",pid=104,fd=3)) uid:518636 ino:4
        LISTEN 0 128 127.0.0.1:8888 0.0.0.0:* uid:518636 ino:5
        LISTEN 0 128 127.0.0.1:10005 0.0.0.0:* users:(("skycore",pid=106,fd=3)) ino:6
        LISTEN 0 128 127.0.0.1:9119 0.0.0.0:* users:(("hermes",pid=107,fd=3)) uid:10000 ino:7
        LISTEN 0 128 127.0.0.1:12000 0.0.0.0:* users:(("docker-proxy",pid=111,fd=3)) ino:11
        LISTEN 0 128 127.0.0.1:32773 0.0.0.0:* users:(("docker-proxy",pid=108,fd=3)) ino:8
        LISTEN 0 128 127.0.0.1:40000 0.0.0.0:* users:(("code",pid=109,fd=3)) uid:518636 ino:9
        __DOCKER__
        root-front|registry.example/root-front:latest|127.0.0.1:12000->80/tcp|volga|root-front
        transformator-poc|gcr.io/k8s-minikube/kicbase:v0.0.50|127.0.0.1:32773->22/tcp||
        __PS__
        100 1 518636 sergeigarin bun /usr/bin/bun run dev
        101 1 518636 sergeigarin node /usr/bin/node /repo/node_modules/vite/bin/vite.js --port 4173
        102 100 518636 sergeigarin node /usr/bin/node server.js --port 4180
        103 1 518636 sergeigarin ruby ruby app.rb --port 7000
        104 1 518636 sergeigarin python3 python3 -m http.server 8765
        105 1 518636 sergeigarin zrok /usr/local/bin/zrok agent start
        106 1 0 root skycore /usr/bin/skycore
        107 1 10000 hermes hermes dashboard --port 9119
        108 1 0 root docker-proxy docker-proxy -host-port 32773 -container-port 22
        109 1 518636 sergeigarin code code --on-port 40000
        110 105 518636 sergeigarin zrok zrok share public http://127.0.0.1:8765 --name-selection public:architecture-p8765
        111 1 0 root docker-proxy docker-proxy -host-port 12000 -container-port 80
        __CWD__
        101|/home/sergeigarin/project-vite
        102|/home/sergeigarin/project-bun
        103|/home/sergeigarin/project-ruby
        104|/home/sergeigarin/artifacts
        105|/home/sergeigarin
        """

        let services = TunnelEngine.services(fromInventoryOutput: output)
        let byPort = Dictionary(uniqueKeysWithValues: services.map { ($0.port, $0) })

        XCTAssertEqual(try XCTUnwrap(byPort[4173]).kind, .vite)
        XCTAssertEqual(try XCTUnwrap(byPort[4180]).kind, .node)
        XCTAssertEqual(try XCTUnwrap(byPort[4180]).name, "Bun")
        XCTAssertEqual(try XCTUnwrap(byPort[7000]).kind, .process)
        XCTAssertEqual(try XCTUnwrap(byPort[8765]).kind, .zrok)
        XCTAssertEqual(try XCTUnwrap(byPort[8765]).name, "zrok Share · architecture-p8765")
        XCTAssertEqual(try XCTUnwrap(byPort[8888]).name, "zrok Admin Panel")
        XCTAssertEqual(try XCTUnwrap(byPort[10005]).group, "Системные сервисы")
        XCTAssertEqual(try XCTUnwrap(byPort[9119]).kind, .hermes)
        XCTAssertEqual(try XCTUnwrap(byPort[9119]).name, "Hermes Dashboard")
        XCTAssertEqual(try XCTUnwrap(byPort[12000]).kind, .docker)
        XCTAssertEqual(try XCTUnwrap(byPort[12000]).group, "volga")
        XCTAssertEqual(try XCTUnwrap(byPort[12000]).name, "root-front")
        XCTAssertEqual(try XCTUnwrap(byPort[32773]).kind, .minikube)
        XCTAssertEqual(try XCTUnwrap(byPort[32773]).name, "Minikube SSH")
        XCTAssertNil(byPort[40000], "Unrelated ephemeral high ports must stay hidden")
    }

    func testInfersUniqueProcessFromUIDAndPortWhenSSCannotExposePID() throws {
        let output = """
        __USER__
        501
        __SS__
        LISTEN 0 128 127.0.0.1:4399 0.0.0.0:* uid:501 ino:10
        __DOCKER__
        __PS__
        200 1 501 demo fish fish -c bun run dashboard --port 4399
        201 200 501 demo bun /usr/local/bin/bun run dashboard --port 4399
        __CWD__
        """

        let service = try XCTUnwrap(
            TunnelEngine.services(fromInventoryOutput: output).first
        )

        XCTAssertEqual(service.kind, .node)
        XCTAssertEqual(service.name, "Bun")
        XCTAssertNotEqual(service.group, "Системные сервисы")
    }

    func testUnknownSocketUIDRemainsUnknownAndCanInferUserProcess() throws {
        let output = """
        __USER__
        501
        __SS__
        LISTEN 0 128 127.0.0.1:4399 0.0.0.0:* ino:10
        __DOCKER__
        __PS__
        201 1 501 demo bun /usr/local/bin/bun run dashboard --port 4399
        __CWD__
        """

        let inventory = RemoteInventoryParser.parse(output)
        let service = try XCTUnwrap(
            TunnelEngine.services(fromInventoryOutput: output).first
        )

        XCTAssertNil(try XCTUnwrap(inventory.listeners.first).userID)
        XCTAssertEqual(service.kind, .node)
        XCTAssertEqual(service.name, "Bun")
    }

    func testRecognizesKubectlPortForwardAsKubernetesService() throws {
        let output = """
        __USER__
        501
        __SS__
        LISTEN 0 4096 127.0.0.1:19012 0.0.0.0:* uid:501 ino:12
        __DOCKER__
        __PS__
        300 1 501 demo fish fish -c kubectl --context transformator-poc -n transformator-poc port-forward service/first-transformator-core-poc-worker-pool 19012:9010
        301 300 501 demo kubectl kubectl --context transformator-poc -n transformator-poc port-forward service/first-transformator-core-poc-worker-pool 19012:9010
        __CWD__
        """

        let service = try XCTUnwrap(
            TunnelEngine.services(fromInventoryOutput: output).first
        )

        XCTAssertEqual(service.kind, .kubernetes)
        XCTAssertEqual(service.name, "first-transformator-core-poc-worker-pool")
        XCTAssertEqual(service.group, "Kubernetes · transformator-poc")
        XCTAssertTrue(service.details.contains("namespace: transformator-poc"))
        XCTAssertTrue(service.details.contains("19012 → 9010"))
    }

    func testKubectlPortForwardDoesNotInventDefaultNamespace() throws {
        let output = """
        __USER__
        501
        __SS__
        LISTEN 0 4096 127.0.0.1:19020 0.0.0.0:* uid:501 ino:20
        __DOCKER__
        __PS__
        320 1 501 demo kubectl kubectl --context staging port-forward service/api 19020:8080
        __CWD__
        """

        let service = try XCTUnwrap(
            TunnelEngine.services(fromInventoryOutput: output).first
        )

        XCTAssertEqual(service.kind, .kubernetes)
        XCTAssertEqual(service.group, "Kubernetes · staging")
        XCTAssertFalse(service.details.contains("namespace:"))
        XCTAssertFalse(service.details.contains("default"))
    }

    func testUnknownSocketOwnerWithoutProcessEvidenceStaysGeneric() throws {
        let output = """
        __USER__
        501
        __SS__
        LISTEN 0 128 127.0.0.1:4400 0.0.0.0:* ino:11
        __DOCKER__
        __PS__
        __CWD__
        """

        let service = try XCTUnwrap(
            TunnelEngine.services(fromInventoryOutput: output).first
        )

        XCTAssertEqual(service.kind, .process)
        XCTAssertNotEqual(service.group, "Системные сервисы")
    }

    func testInventoryNeverAttemptsPrivilegeEscalation() {
        XCTAssertFalse(TunnelEngine.inventoryScript.contains("sudo"))
        XCTAssertTrue(TunnelEngine.inventoryScript.contains("ss -H -ltnpe"))
    }
}
