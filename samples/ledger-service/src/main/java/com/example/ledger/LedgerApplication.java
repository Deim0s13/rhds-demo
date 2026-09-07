package com.example.ledger;

import java.util.List;
import java.util.Map;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class LedgerApplication {

    public static void main(String[] args) {
        SpringApplication.run(LedgerApplication.class, args);
    }

    @GetMapping("/api/ledger")
    public List<Map<String, Object>> entries() {
        return List.of(
            Map.of("account", "NZ-0001", "balance", 4210.00, "currency", "NZD")
        );
    }
}
