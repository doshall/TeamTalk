<?php if ( ! defined('BASEPATH')) exit('No direct script access allowed');

class Api extends CI_Controller {

	public function __construct()
	{
		parent::__construct();
		$this->load->helper('url');
		$this->load->model('discovery_model');
	}

	// Public endpoint for IM clients (see loginserver.conf discovery URL).
	public function discovery()
	{
		if (strtolower($this->input->server('REQUEST_METHOD')) !== 'get') {
			show_error('Method Not Allowed', 405);
			return;
		}

		$data = $this->discovery_model->getList(array('status'=>0));
		$result = array();
		foreach ($data as $row) {
			$result[] = array(
				'itemName' => $row['itemName'],
				'itemUrl' => $row['itemUrl'],
				'itemPriority' => $row['itemPriority']
			);
		}
		$this->output
			->set_content_type('application/json')
			->set_output(json_encode($result));
	}
}
