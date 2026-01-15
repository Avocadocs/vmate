module vmate5

import json
import os

@[heap]
pub struct GrammarRegistry {
mut:
	max_tokens_per_line       int
	max_line_length           int
	null_grammar              NullGrammar
	grammars                  []Grammar
	grammars_by_scope_name    map[string]&Grammar
	injection_grammars        []&Grammar
	grammar_overrides_by_path map[string]&Grammar
	scopes_id_counter         int = -1
	ids_by_scope              map[string]int
	scopes_by_id              map[string]string
}

pub fn (mut gr GrammarRegistry) clear() {
	gr.grammars = []
	gr.grammars_by_scope_name = {}
	gr.injection_grammars = []
	gr.grammar_overrides_by_path = {}
	gr.scopes_id_counter = -1
	gr.ids_by_scope = {}
	gr.scopes_by_id = {}
}

pub fn (gr &GrammarRegistry) grammar_for_scope_name(scope_name string) ?&Grammar {
	return gr.grammars_by_scope_name[scope_name] or { none }
}

pub fn (mut gr GrammarRegistry) add_grammar(grammar Grammar) {
	gr.grammars << &grammar
	gr.grammars_by_scope_name[grammar.scope_name] = &grammar
}

pub fn (mut gr GrammarRegistry) remove_grammar(grammar Grammar) {
}

pub fn (mut gr GrammarRegistry) remove_grammar_for_scope_name(scope_name string) {
}

pub fn (mut gr GrammarRegistry) read_grammar_sync(grammar_path string) Grammar {
	grammar_content := os.read_file(grammar_path) or { panic(err) }

	raw_grammar := json.decode(GrammarOptions, grammar_content) or {
		panic('Failed to parse grammar JSON: ${err}')
	}

	if raw_grammar.scope_name.len > 0 {
		return gr.create_grammar(grammar_path, raw_grammar)
	} else {
		panic('Grammar missing required scopeName: ${grammar_path}')
	}
}

pub fn (mut gr GrammarRegistry) load_grammar_sync(grammar_path string) Grammar {
	mut grammar := gr.read_grammar_sync(grammar_path)
	gr.add_grammar(grammar)

	return grammar
}

pub fn (mut gr GrammarRegistry) start_id_for_scope(scope string) int {
	if scope !in gr.ids_by_scope {
		id := gr.scopes_id_counter
		gr.scopes_id_counter -= 2
		gr.ids_by_scope[scope] = id
		gr.scopes_by_id[id.str()] = scope

		return id
	} else {
		return gr.ids_by_scope[scope]
	}
}

pub fn (mut gr GrammarRegistry) end_id_for_scope(scope string) int {
	return gr.start_id_for_scope(scope) - 1
}

pub fn (gr &GrammarRegistry) scope_for_id(id int) string {
	if id % 2 == -1 {
		return gr.scopes_by_id[id.str()]
	} else {
		return gr.scopes_by_id[(id + 1).str()]
	}
}

pub fn (mut gr GrammarRegistry) create_grammar(grammar_path string, raw GrammarOptions) Grammar {
	mut grammar := new_grammar(gr, raw)
	grammar.path = grammar_path

	return grammar
}

pub struct Token {
pub:
	value  string
	scopes []string
}

// to do implement fn parameter
pub fn (gr &GrammarRegistry) decode_tokens(line_text string, tags []int, mut scope_tags []int) []Token {
	mut offset := 0

	mut scope_names := scope_tags.map(fn [gr] (tag int) string {
		return gr.scope_for_id(tag)
	})

	mut tokens := []Token{}

	for _, tag in tags {
		if tag >= 0 {
			token := Token{
				value:  line_text.substr(offset, offset + tag)
				scopes: scope_names.clone()
			}
			tokens << token
			offset += tag
		} else if tag % 2 == -1 {
			scope_tags << tag
			scope_names << gr.scope_for_id(tag)
		} else {
			scope_tags.pop()
			expected_scope_name := gr.scope_for_id(tag + 1)
			popped_scope_name := scope_names.pop()
			if popped_scope_name != expected_scope_name {
				panic('Unexpected scope name ${popped_scope_name}')
			}
		}
	}

	return tokens
}
