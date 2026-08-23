<?php
// Smallest real WordPress-plugin wiring: store a team API key (Settings API), then
// push each published post to your API. Swap YOUR_PRODUCT_API_BASE + the payload
// for your product's public REST API contract. Rename the `your_product` prefix
// to your approved slug everywhere.

/**
 * Plugin Name:       Your Product
 * Description:       Push published posts to your product via its public REST API.
 * Version:           1.0.0
 * Requires at least: 6.0
 * Requires PHP:      7.4
 * License:           GPL-2.0-or-later
 * Text Domain:       your-product
 */

defined( 'ABSPATH' ) || exit; // required guard in every PHP file

define( 'YOUR_PRODUCT_API_BASE', 'https://api.example.com/v1' );

// --- Settings: one array option, sanitized on the way in ---
add_action(
	'admin_init',
	function () {
		register_setting(
			'your_product',
			'your_product_settings',
			array(
				'sanitize_callback' => function ( $input ) {
					$input = is_array( $input ) ? $input : array();
					return array(
						'api_key' => isset( $input['api_key'] ) ? sanitize_text_field( $input['api_key'] ) : '',
					);
				},
			)
		);
	}
);

// --- save_post → POST to your API (guard autosave/revision first) ---
add_action(
	'save_post',
	function ( $post_id, $post ) {
		if ( wp_is_post_autosave( $post_id ) || wp_is_post_revision( $post_id ) ) {
			return;
		}
		if ( 'publish' !== $post->post_status || ! current_user_can( 'edit_post', $post_id ) ) {
			return;
		}

		$options = get_option( 'your_product_settings', array() );
		$key     = isset( $options['api_key'] ) ? $options['api_key'] : '';
		if ( '' === $key ) {
			return;
		}

		$res = wp_remote_request( // never raw curl / file_get_contents — WPCS flags both
			YOUR_PRODUCT_API_BASE . '/posts',
			array(
				'method'  => 'POST',
				'timeout' => 30,
				'headers' => array(
					'Authorization' => 'Bearer ' . $key,
					'Content-Type'  => 'application/json; charset=utf-8',
				),
				'body'    => wp_json_encode(
					array(
						'title'     => get_the_title( $post ),
						'permalink' => get_permalink( $post ),
					)
				),
			)
		);

		if ( is_wp_error( $res ) || wp_remote_retrieve_response_code( $res ) >= 300 ) {
			update_post_meta( $post_id, '_your_product_last_error', 'API call failed' ); // surface, don't swallow
		}
	},
	20,
	2
);

// --- The guard triplet reviewers grep for, on any $_POST handler ---
add_action(
	'admin_post_your_product_action',
	function () {
		if ( ! isset( $_POST['your_product_nonce'] ) ) {
			wp_die( 'Missing nonce' );
		}
		if ( ! wp_verify_nonce( sanitize_text_field( wp_unslash( $_POST['your_product_nonce'] ) ), 'your_product_action' ) ) {
			wp_die( 'Bad nonce' );
		}
		if ( ! current_user_can( 'manage_options' ) ) {
			wp_die( 'Denied' );
		}
		// ... sanitize each field, then act. In the form: wp_nonce_field( 'your_product_action', 'your_product_nonce' );
		wp_safe_redirect( admin_url( 'options-general.php?page=your-product&done=1' ) );
		exit;
	}
);
