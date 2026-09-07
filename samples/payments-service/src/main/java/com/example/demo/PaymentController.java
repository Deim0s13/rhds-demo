package com.example.demo;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Deliberately small. During the demo the live edit is adding a new endpoint
 * here and watching devtools reload inside the workspace, first from the
 * browser IDE and then from the desktop IDE attached to the same container.
 */
@RestController
@RequestMapping("/api/payments")
public class PaymentController {

    @GetMapping
    public List<Map<String, Object>> list() {
        return List.of(
            Map.of("id", "PMT-1001", "amount", 125.50, "currency", "NZD", "status", "SETTLED"),
            Map.of("id", "PMT-1002", "amount", 89.99, "currency", "NZD", "status", "PENDING")
        );
    }

    @GetMapping("/health-summary")
    public Map<String, Object> healthSummary() {
        return Map.of(
            "service", "payments",
            "checkedAt", Instant.now().toString(),
            "status", "UP"
        );
    }
}
