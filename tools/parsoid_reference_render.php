<?php
declare( strict_types = 1 );

require_once __DIR__ . '/parsoid-php/vendor/autoload.php';

use Wikimedia\Parsoid\DOM\Element;
use Wikimedia\Parsoid\Mocks\MockDataAccess;
use Wikimedia\Parsoid\Mocks\MockPageConfig;
use Wikimedia\Parsoid\Mocks\MockPageContent;
use Wikimedia\Parsoid\Mocks\MockSiteConfig;
use Wikimedia\Parsoid\Parsoid;
use Wikimedia\Parsoid\ParserTests\TestUtils;
use Wikimedia\Parsoid\Utils\ContentUtils;
use Wikimedia\Parsoid\Utils\DOMCompat;
use Wikimedia\Parsoid\Utils\DOMUtils;

function parseArgs( array $argv ): array {
	$title = 'Test';
	for ( $i = 1; $i < count( $argv ); $i++ ) {
		$arg = $argv[$i];
		if ( $arg === '--title' && isset( $argv[$i + 1] ) ) {
			$title = $argv[++$i];
			continue;
		}
		throw new RuntimeException( "unexpected argument: $arg" );
	}
	return [ 'title' => $title ];
}

function flushRenderedSection( array &$sections, string $title, int $level, array &$buffer ): void {
	$html = trim( implode( '', $buffer ), " \n\t\r" );
	$buffer = [];
	if ( $html === '' ) {
		return;
	}
	$sections[] = sprintf( "@%d:%s\n%s", $level, $title, $html );
}

function renderCanonicalReference( string $title, string $raw ): string {
	$siteConfig = new MockSiteConfig( [ 'title' => $title ] );
	$dataAccess = new MockDataAccess( $siteConfig, [ 'title' => $title ] );
	$parsoid = new Parsoid( $siteConfig, $dataAccess );

	$content = new MockPageContent( [ 'main' => $raw ] );
	$pageConfig = new MockPageConfig( $siteConfig, [ 'title' => $title ], $content );

	$html = $parsoid->wikitext2html( $pageConfig, [
		'body_only' => true,
		'wrapSections' => false,
	] );
	$normalized = TestUtils::normalizeOut( $html );
	$body = DOMCompat::getBody( DOMUtils::parseHTML( $normalized ) );
	$sections = [];
	$buffer = [];
	$currentTitle = '';
	$currentLevel = 1;
	$seenEnglish = false;

	foreach ( DOMUtils::childNodes( $body ) as $node ) {
		if ( $node instanceof Element ) {
			$name = DOMUtils::nodeName( $node );
			if ( preg_match( '/^h([2-6])$/', $name, $matches ) ) {
				$level = intval( $matches[1] );
				$headingTitle = trim( $node->textContent );
				if ( $level === 2 && $headingTitle === 'English' ) {
					if ( $seenEnglish ) {
						flushRenderedSection( $sections, $currentTitle, $currentLevel, $buffer );
					}
					$seenEnglish = true;
					$currentTitle = '';
					$currentLevel = 1;
					$buffer = [];
					continue;
				}
				if ( !$seenEnglish ) {
					continue;
				}
				flushRenderedSection( $sections, $currentTitle, $currentLevel, $buffer );
				$currentTitle = $headingTitle;
				$currentLevel = $level;
				$buffer = [];
				continue;
			}
		}

		if ( !$seenEnglish ) {
			continue;
		}
		$buffer[] = ContentUtils::toXML( $node );
	}

	if ( $seenEnglish ) {
		flushRenderedSection( $sections, $currentTitle, $currentLevel, $buffer );
	}

	return implode( "\n", $sections );
}

try {
	$args = parseArgs( $argv );
	$raw = file_get_contents( 'php://stdin' );
	if ( $raw === false ) {
		throw new RuntimeException( 'failed to read stdin' );
	}

	fwrite( STDOUT, renderCanonicalReference( $args['title'], $raw ) );
} catch ( Throwable $e ) {
	fwrite( STDERR, $e->getMessage() . "\n" );
	exit( 1 );
}
