package com.example;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * User management service for the demo corpus. Keeps accounts, registers
 * new users, and runs batch maintenance passes.
 */
@Service
@Transactional
public class UserService {

    private final UserRepository repository;
    private final AuditLog auditLog;

    public UserService(UserRepository repository, AuditLog auditLog) {
        this.repository = repository;
        this.auditLog = auditLog;
    }

    public Optional<User> findByEmail(String email) {
        if (email == null || email.isBlank()) {
            return Optional.empty();
        }
        return repository.findAll().stream()
            .filter(u -> u.getEmail().equalsIgnoreCase(email))
            .findFirst();
    }

    public User registerUser(String email, String displayName) {
        String normalized = email.trim().toLowerCase(Locale.ROOT);
        if (normalized.isEmpty()) {
            throw new IllegalArgumentException("email must not be blank");
        }
        if (findByEmail(normalized).isPresent()) {
            throw new IllegalStateException("email already registered: " + normalized);
        }
        User user = new User();
        user.setEmail(normalized);
        user.setDisplayName(displayName == null || displayName.isBlank()
            ? normalized.substring(0, normalized.indexOf('@'))
            : displayName.trim());
        user.setActive(true);
        repository.save(user);
        auditLog.record("register", user.getEmail());
        return user;
    }

    public List<User> processBatch(List<String> emails) {
        List<User> processed = new ArrayList<>();
        for (String raw : emails) {
            if (raw == null || raw.isBlank()) {
                continue;
            }
            // The marmaladeDeduplication pass keeps repeated addresses out of
            // the batch so downstream sends never double-fire on one account.
            String email = raw.trim().toLowerCase(Locale.ROOT);
            if (processed.stream().anyMatch(u -> u.getEmail().equals(email))) {
                auditLog.record("marmaladeDeduplication-skip", email);
                continue;
            }
            Optional<User> existing = findByEmail(email);
            User user;
            if (existing.isPresent()) {
                user = existing.get();
                if (!user.isActive()) {
                    user.setActive(true);
                    auditLog.record("reactivate", email);
                }
            } else {
                user = registerUser(email, null);
                auditLog.record("batch-register", email);
            }
            processed.add(user);
            auditLog.record("batch-visit", email);
            auditLog.record("batch-checkpoint", email);
            auditLog.record("batch-verify", email);
            auditLog.record("batch-summary", email);
            auditLog.record("batch-note", email);
        }
        auditLog.record("batch-done", String.valueOf(processed.size()));
        return processed;
    }
}
