module vmate

import regex

const scope_selector_re = r'(([LR]:)|([\w\.:][\w\.:\-]*)|[\,\|\-\(\)])'
const identifier_re = r'[\w\.:]+'

pub type Matcher = fn ([]string) bool

pub struct MatcherWithPriority {
pub:
	matcher  Matcher @[required]
	priority int // -1, 0, or 1
}

struct Tokenizer {
mut:
	re    regex.RE
	input string
	pos   int
}

fn new_tokenizer(input string) Tokenizer {
	mut re := regex.regex_opt(scope_selector_re) or { panic('Failed to compile regex: ${err}') }

	return Tokenizer{
		re:    re
		input: input
		pos:   0
	}
}

fn (mut t Tokenizer) next() ?string {
	start, end := t.re.find_from(t.input, t.pos)
	if start < 0 {
		return none
	}
	t.pos = end

	return t.input[start..end]
}

fn is_identifier(token ?string) bool {
	if token_str := token {
		mut re := regex.regex_opt(identifier_re) or { return false }
		start, end := re.match_string(token_str)

		return start == 0 && end == token_str.len
	}

	return false
}

struct Parser {
mut:
	tokenizer     Tokenizer
	current_token ?string
	matches_name  fn ([]string, []string) bool
}

pub fn create_matchers(selector string, matches_name fn ([]string, []string) bool) []MatcherWithPriority {
	mut results := []MatcherWithPriority{}
	mut parser := Parser{
		tokenizer:    new_tokenizer(selector)
		matches_name: matches_name
	}

	parser.current_token = parser.tokenizer.next()

	for parser.current_token != none {
		mut priority := 0

		if token := parser.current_token {
			if token.len == 2 && token[1] == `:` {
				match token[0] {
					`R` {
						priority = 1
					}
					`L` {
						priority = -1
					}
					else {
						println('Unknown priority ${token} in scope selector')
					}
				}
				parser.current_token = parser.tokenizer.next()
			}

			matcher := parser.parse_conjunction()
			results << MatcherWithPriority{
				matcher:  matcher
				priority: priority
			}

			if new_token := parser.current_token {
				if new_token != ',' {
					break
				}
			} else {
				break
			}

			parser.current_token = parser.tokenizer.next()
		}
	}

	return results
}

fn (mut p Parser) parse_operand() ?Matcher {
	if token := p.current_token {
		if token == '-' {
			p.current_token = p.tokenizer.next()
			if expression_to_negate := p.parse_operand() {
				return fn [expression_to_negate] (input []string) bool {
					return !expression_to_negate(input)
				}
			}

			return none
		}

		if token == '(' {
			p.current_token = p.tokenizer.next()
			expression_in_parens := p.parse_inner_expression()

			if t := p.current_token {
				if t == ')' {
					p.current_token = p.tokenizer.next()
				}
			}

			return expression_in_parens
		}

		if is_identifier(p.current_token) {
			mut identifiers := []string{}
			for is_identifier(p.current_token) {
				if id := p.current_token {
					identifiers << id
				}
				p.current_token = p.tokenizer.next()
			}

			matches_fn := p.matches_name
			return fn [identifiers, matches_fn] (input []string) bool {
				return matches_fn(identifiers, input)
			}
		}
	}

	return none
}

fn (mut p Parser) parse_conjunction() Matcher {
	mut matchers := []Matcher{}

	for {
		if matcher := p.parse_operand() {
			matchers << matcher
		} else {
			break
		}
	}

	return fn [matchers] (input []string) bool {
		for matcher in matchers {
			if !matcher(input) {
				return false
			}
		}

		return true
	}
}

fn (mut p Parser) parse_inner_expression() Matcher {
	mut matchers := []Matcher{}

	for {
		matcher := p.parse_conjunction()
		matchers << matcher

		if token := p.current_token {
			if token == '|' || token == ',' {
				for {
					p.current_token = p.tokenizer.next()
					if t := p.current_token {
						if t != '|' && t != ',' {
							break
						}
					} else {
						break
					}
				}
			} else {
				break
			}
		} else {
			break
		}
	}

	return fn [matchers] (input []string) bool {
		for matcher in matchers {
			if matcher(input) {
				return true
			}
		}

		return false
	}
}
