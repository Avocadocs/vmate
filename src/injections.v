module vmate

import regex

struct Injection {
mut:
	selector_source string
	selector        ScopeSelector
	patterns        []Pattern
	scanner         ?Scanner
}

pub struct Injections {
mut:
	grammar    &Grammar = unsafe { nil }
	injections []Injection
}

pub fn new_injections(mut grammar Grammar, injections map[string]PatternOptions) Injections {
	mut result_injections := []Injection{}

	for selector, values in injections {
		if values.patterns.len == 0 {
			continue
		}

		mut patterns := []Pattern{}
		mut included := []&Rule{}

		for regex in values.patterns {
			mut pattern := grammar.create_pattern(regex)
			included_patterns := pattern.get_included_patterns(&grammar, mut included)
			patterns << included_patterns
		}

		result_injections << Injection{
			selector:        new_scope_selector(selector) or { panic(err) }
			patterns:        patterns
			selector_source: selector
		}
	}

	return Injections{
		grammar:    &grammar
		injections: result_injections
	}
}

fn (mut i Injections) get_scanner(mut injection Injection) Scanner {
	if scanner := injection.scanner {
		return scanner
	}

	scanner := new_scanner(injection.patterns)
	injection.scanner = scanner

	return scanner
}

pub struct ScannerWithPriority {
pub:
	scanner  Scanner
	priority int
}

pub fn (mut i Injections) get_scanners(rule_stack []&StackItem) []Scanner {
	if i.injections.len == 0 {
		return []
	}

	mut scanners := []Scanner{}
	scopes := i.grammar.scopes_from_stack(rule_stack, &Rule{}, false)

	for mut injection in i.injections {
		if injection.selector.matches(scopes) {
			scanner := i.get_scanner(mut injection)
			scanners << scanner
		}
	}

	return scanners
}

fn name_matcher(identifers []string, scopes []string) bool {
	if scopes.len < identifers.len {
		return false
	}
	mut last_index := 0
	return identifers.all(fn [mut last_index, scopes] (identifier string) bool {
		for i := last_index; i < scopes.len; i++ {
			if scopes_are_matching(scopes[i], identifier) {
				last_index = i + 1
				return true
			}
		}

		return false
	})
}

fn scopes_are_matching(this_scope_name string, scope_name string) bool {
	if this_scope_name == '' {
		return false
	}
	if this_scope_name == scope_name {
		return true
	}

	len := scope_name.len

	return this_scope_name.len > len && this_scope_name.substr(0, len) == scope_name
		&& this_scope_name[len] == `.`
}
