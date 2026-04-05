<?php
declare( strict_types = 1 );

require dirname( __DIR__ ) . '/parsoid-php/vendor/autoload.php';

use Wikimedia\Parsoid\Config\Api\ApiHelper;
use Wikimedia\Parsoid\Config\Api\DataAccess;
use Wikimedia\Parsoid\Config\Api\PageConfig;
use Wikimedia\Parsoid\Config\Api\SiteConfig;
use Wikimedia\Parsoid\Config\StubMetadataCollector;
use Wikimedia\Parsoid\Parsoid;
use Wikimedia\Parsoid\Utils\Title as ParsoidTitle;

ini_set( 'display_errors', 'stderr' );

$config = [
	'standalone' => true,
	'apiEndpoint' => getenv( 'PARSOID_API_URL' ) ?: 'https://en.wiktionary.org/w/api.php',
	'userAgent' => getenv( 'PARSOID_USER_AGENT' ) ?: 'dict-parsoid-audit/1.0 (local tool; contact: local)',
	'addHTMLTemplateParameters' => false,
	'linting' => false,
	'mock' => false,
	'cacheDir' => getenv( 'PARSOID_API_CACHE_DIR' ) ?: null,
	'writeToCache' => getenv( 'PARSOID_API_WRITE_CACHE' ) ?: 'pretty',
];

$api = new ApiHelper( $config );
$siteConfig = new SiteConfig( $api, $config );
$siteConfig->setLogger( SiteConfig::createLogger( 'php://stderr' ) );
$dataAccess = new DataAccess( $api, $siteConfig, $config );
$parsoid = new Parsoid( $siteConfig, $dataAccess );

while ( ( $line = fgets( STDIN ) ) !== false ) {
	$line = trim( $line );
	if ( $line === '' ) {
		continue;
	}

	try {
		$request = json_decode( $line, true, 512, JSON_THROW_ON_ERROR );
		$titleText = (string)( $request['title'] ?? 'Test' );
		$raw = (string)( $request['raw'] ?? '' );

		$title = ParsoidTitle::newFromText( $titleText, $siteConfig );
		$pageConfig = new PageConfig( $api, $siteConfig, [
			'title' => $title,
			'pageContent' => $raw,
			'loadData' => true,
		] );
		$headers = null;
		$metadata = new StubMetadataCollector( $siteConfig );
		$html = $parsoid->wikitext2html(
			$pageConfig,
			[
				'body_only' => true,
				'wrapSections' => false,
				'logLevels' => [ 'fatal', 'error', 'warn' ],
			],
			$headers,
			$metadata
		);

		echo json_encode(
			[
				'ok' => true,
				'html' => $html,
			],
			JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
		) . "\n";
	} catch ( Throwable $error ) {
		echo json_encode(
			[
				'ok' => false,
				'kind' => 'parsoid_error',
				'summary' => $error->getMessage(),
			],
			JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
		) . "\n";
	}
}
