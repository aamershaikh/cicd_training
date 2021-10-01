package com.deloitte.com.cicdtraining.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class Api {

    @GetMapping("/message")
    public String getMessage(){
        return "Hello World - From Deloitte";
    }
}
